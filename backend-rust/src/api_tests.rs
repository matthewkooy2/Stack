use super::*;

fn database() -> Connection {
    let db = open(":memory:").unwrap();
    auth::init(&db).unwrap();
    account::init(&db).unwrap();
    jobs::init(&db).unwrap();
    resumes::init(&db).unwrap();
    recording::init(&db).unwrap();
    career::init(&db).unwrap();
    db
}
fn register(db: &mut Connection, user: &str) -> String {
    let (_, body) = auth::identity(
        db,
        true,
        &json!({"identities":[{"type":"username","value":user}],
        "credential":{"type":"password","password":"synthetic fixture only"}}),
        "",
    )
    .unwrap();
    body["data"]["token"].as_str().unwrap().to_owned()
}

#[test]
fn invitation_is_one_use_and_deletion_revokes_every_session() {
    let mut db = database();
    let alpha = register(&mut db, "fixture-alpha");
    let beta = register(&mut db, "fixture-beta");
    let invite = auth::new_invite(&db).unwrap();
    assert_eq!(
        rpc(
            &mut db,
            "agent_accept_invite",
            &alpha,
            &json!({"invite":invite})
        )
        .unwrap()
        .1["data"]["result"]["admitted"],
        true
    );
    assert!(
        rpc(
            &mut db,
            "agent_accept_invite",
            &beta,
            &json!({"invite":invite})
        )
        .unwrap()
        .1["data"]["result"]["error"]
            .is_string()
    );
    let owner = auth::principal(&db, &alpha).unwrap().unwrap().0;
    let (_, login) = auth::identity(
        &mut db,
        false,
        &json!({"identity":{"type":"username","value":"fixture-alpha"},
        "credential":{"type":"password","password":"synthetic fixture only"}}),
        "",
    )
    .unwrap();
    let second = login["data"]["token"].as_str().unwrap();
    assert_eq!(auth::principal(&db, second).unwrap().unwrap().0, owner);
    let malformed = rpc(
        &mut db,
        "account_delete",
        &alpha,
        &json!({"username":false,"password":[]}),
    )
    .unwrap();
    assert!(malformed.1["data"]["result"]["error"].is_string());
    assert!(auth::principal(&db, &alpha).unwrap().is_some());
    let wrong = rpc(
        &mut db,
        "account_delete",
        &alpha,
        &json!({"username":"fixture-beta","password":"synthetic fixture only"}),
    )
    .unwrap();
    assert!(wrong.1["data"]["result"]["error"].is_string());
    assert_eq!(
        rpc(&mut db, "account_delete", &alpha, &json!({}))
            .unwrap()
            .1["data"]["result"]["deleted"],
        true
    );
    for dead in [&alpha, second] {
        assert_eq!(
            rpc(&mut db, "agent_admission", dead, &json!({})).unwrap().0,
            StatusCode::UNAUTHORIZED
        );
        assert!(auth::unknown_user(&db, dead).unwrap());
    }
    assert!(auth::principal(&db, &beta).unwrap().is_some());
}

#[test]
fn invalid_policy_and_fact_batches_preserve_the_last_accepted_state() {
    let mut db = database();
    let token = register(&mut db, "fixture-policy");
    let invite = auth::new_invite(&db).unwrap();
    rpc(
        &mut db,
        "agent_accept_invite",
        &token,
        &json!({"invite":invite}),
    )
    .unwrap();
    let run = |db: &mut Connection, m: &str, a: Value| {
        rpc(db, m, &token, &a).unwrap().1["data"]["result"].clone()
    };
    let saved = run(
        &mut db,
        "agent_save_facts",
        json!({"facts":[{"key":"email","value":"synthetic@example.invalid","verified":true}]}),
    );
    assert_eq!(saved["facts"][0]["verified"], true);
    assert!(
        run(
            &mut db,
            "agent_save_facts",
            json!({"facts":[{"key":"email","value":"invalid"}]})
        )["error"]
            .is_string()
    );
    assert!(
        run(
            &mut db,
            "agent_save_policy",
            json!({"policy":{"enabled":true,"actions":["calendar_write"],"expires_at":0}})
        )["error"]
            .is_string()
    );
    let exported = run(&mut db, "account_export", json!({}));
    assert_eq!(exported["agents"]["settings"]["facts"], saved["facts"]);
    assert_eq!(
        exported["agents"]["settings"]["revision"],
        saved["revision"]
    );
}

#[test]
fn forwarded_client_requires_configured_ingress() {
    let peer: IpAddr = "127.0.0.1".parse().unwrap();
    let expected: IpAddr = "192.0.2.16".parse().unwrap();
    let mut headers = HeaderMap::new();
    headers.insert("x-forwarded-for", "192.0.2.1, 192.0.2.16".parse().unwrap());
    assert_eq!(client_address(peer, None, &headers), peer);
    assert_eq!(client_address(peer, Some(peer), &headers), expected);
}

#[test]
fn account_sessions_share_one_window_and_other_traffic_has_its_own_allowance() {
    let mut db = database();
    let first = register(&mut db, "budget-owner");
    let (_, body) = auth::identity(
        &mut db,
        false,
        &json!({"identity":{"type":"username","value":"budget-owner"},
        "credential":{"type":"password","password":"synthetic fixture only"}}),
        "",
    )
    .unwrap();
    let second = body["data"]["token"].as_str().unwrap();
    assert_ne!(first, second);
    let other = register(&mut db, "budget-other");
    let owner = |token| auth::principal(&db, token).unwrap().unwrap().0;
    let sessions = [owner(&first), owner(second)];
    let client: IpAddr = "127.0.0.1".parse().unwrap();
    let mut rates = RateLimits::default();
    for i in 0..300 {
        assert!(rates.admit(Allowance::Account(sessions[i % 2].clone()), 120));
    }
    for session in &sessions {
        assert!(!rates.admit(Allowance::Account(session.clone()), 120));
    }
    assert!(rates.admit(Allowance::Account(owner(&other)), 120));
    for _ in 0..300 {
        assert!(rates.admit(Allowance::Anonymous(client), 120));
        assert!(rates.admit(Allowance::Poll(client), 120));
        assert!(rates.admit(Allowance::Identity(client), 120));
    }
    assert!(!rates.admit(Allowance::Anonymous(client), 120));
    assert!(!rates.admit(Allowance::Identity(client), 120));
    assert!(!rates.admit(Allowance::Poll(client), 120));
    for key in [
        Allowance::Account(sessions[0].clone()),
        Allowance::Anonymous(client),
        Allowance::Identity(client),
        Allowance::Poll(client),
    ] {
        assert!(rates.admit(key, 121));
    }
}

#[test]
fn workspace_reads_only_its_visible_events_and_exports_dismissed_history() {
    let db = database();
    assert!(account::handles("agent_events"));
    for (owner, kind, id, data) in [
        ("a", "mail_event", "e1", json!({"subject":"Fixture"})),
        ("a", "mail_event", "hidden", json!({"dismissed":true})),
        ("b", "mail_event", "foreign", json!({})),
        ("a", "story", "s1", json!({"id":"s1","created_at":10})),
        ("b", "story", "s2", json!({"id":"s2","created_at":20})),
        (
            "a",
            "calendar_interview",
            "c1",
            json!({"application_id":"app1","study_plan":[]}),
        ),
    ] {
        db.execute(
            "INSERT INTO career_records(owner,kind,id,data,updated) VALUES(?,?,?,?,1)",
            rusqlite::params![owner, kind, id, data],
        )
        .unwrap();
    }
    let result = account::dispatch(&db, "a", "agent_events", &json!({}))
        .unwrap()
        .unwrap();
    assert_eq!(result["events"], json!([{"id":"e1","subject":"Fixture"}]));
    assert_eq!(result["interviews"][0]["id"], "c1");
    let archive = account::dispatch(&db, "a", "agent_export", &json!({}))
        .unwrap()
        .unwrap();
    assert_eq!(archive["events"].as_array().unwrap().len(), 2);
    let full = account::dispatch(&db, "a", "account_export", &json!({}))
        .unwrap()
        .unwrap();
    assert_eq!(full["stories"], json!([{"id":"s1"}]));
}
