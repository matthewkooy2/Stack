use super::*;
fn open() -> Connection {
    let db = Connection::open_in_memory().unwrap();
    init(&db).unwrap();
    crate::account::init(&db).unwrap();
    db.execute_batch("CREATE TABLE resumes(id TEXT PRIMARY KEY,owner TEXT,name TEXT,digest TEXT,review TEXT,revision INTEGER,confirmed INTEGER)").unwrap();
    db
}
fn rpc(db: &Connection, owner: &str, method: &str, a: Value) -> Value {
    dispatch(db, owner, method, &a).unwrap().unwrap()
}

#[test]
fn contact_import_is_atomic_and_account_scoped() {
    let db = open();
    let a = "demo-a";
    let bad = "name,email\nGood,good@example.org\nBad,not-an-email";
    assert!(rpc(&db, a, "agent_import_contacts", json!({"content":bad}))["error"].is_string());
    assert_eq!(
        rpc(&db, a, "agent_contacts", json!({}))["contacts"],
        json!([])
    );
    let contacts = rpc(
        &db,
        a,
        "agent_import_contacts",
        json!({"content":"name,email\n\"Case, Pat\",p@example.org\nTwo,P@example.org"}),
    );
    let contact = &contacts["contacts"][0];
    assert_eq!(contacts["contacts"].as_array().unwrap().len(), 1);
    assert_eq!(contact["name"], "Case, Pat");
    let key = &contact["id"];
    assert!(rpc(&db, "demo-b", "agent_stop_contact", json!({"id":key}))["error"].is_string());
    assert_eq!(
        rpc(&db, a, "agent_stop_contact", json!({"id":key}))["contacts"][0]["stopped"],
        true
    );
    assert_eq!(
        rpc(
            &db,
            a,
            "agent_save_contact",
            json!({"id":key,"data":{"name":"Private","selected":true,"stopped":false}})
        )["contacts"][0]["stopped"],
        true
    );
}

#[test]
fn coaching_replay_keeps_newer_draft_and_private_history() {
    let db = open();
    let p = rpc(
        &db,
        "a",
        "prep_create",
        json!({"problem_id":"project","application_id":"saved-role"}),
    );
    let key = &p["id"];
    let mut sent = p["data"].clone();
    sent["answer"] = json!("Submitted answer");
    let mut newer = sent.clone();
    newer["answer"] = json!("Newer draft");
    let args = json!({"id":key,"data":newer,"revision":0});
    assert_eq!(rpc(&db, "a", "prep_save", args.clone())["revision"], 1);
    assert!(rpc(&db, "a", "prep_save", args)["error"].is_string());
    let mut save = json!({"id":key,"submission":{"revision":0,"key":"request-1","data":sent,"feedback":{"text":"Saved feedback"}}});
    let stored = rpc(&db, "a", "prep_save_coaching", save.clone());
    assert_eq!(stored["data"]["answer"], "Newer draft");
    assert_eq!(stored["feedback"][0]["answer"], "Submitted answer");
    assert_eq!(rpc(&db, "a", "prep_save_coaching", save.clone()), stored);
    save["submission"]["feedback"]["text"] = json!("Changed");
    assert!(rpc(&db, "a", "prep_save_coaching", save)["error"].is_string());
    assert_eq!(
        rpc(&db, "b", "prep_get", json!({"id":key})),
        err("Practice session not found.")
    );
    assert_eq!(
        rpc(&db, "a", "prep_progress", json!({}))["attempts"][0]["feedback"],
        stored["feedback"]
    );
}

#[test]
fn practice_industry_and_question_order() {
    let db = open();
    assert_eq!(
        rpc(&db, "a", "practice_slots", json!({}))["needs_industry"],
        true
    );
    assert_eq!(
        rpc(&db, "a", "practice_profile", json!({"industry":"software"}))["industry"],
        "software"
    );
    let view = rpc(&db, "a", "practice_slots", json!({}));
    let slots = view["slots"].as_array().unwrap();
    assert!(slots.len() >= 4);
    assert!(
        slots
            .windows(2)
            .all(|q| q[0]["question"]["order"].as_i64() <= q[1]["question"]["order"].as_i64())
    );
    assert_eq!(rpc(&db, "b", "practice_options", json!({}))["industry"], "");
}

#[test]
fn bank_confirms_typed_fields_and_pins_selection() {
    let db = open();
    db.execute(
        "INSERT INTO resumes VALUES ('resume','a','test','sha',?,1,1)",
        [json!({"records":[{"id":"r0","kind":"title","text":"Profile"}]}).to_string()],
    )
    .unwrap();
    let mut group = json!({"name":"Internship","source":"notes","entry_type":"work_experience","fields":{},"records":[{"id":"r0","kind":"bullet","text":"Built a fixture"}],"confirm":true});
    assert!(
        rpc(&db, "a", "resume_bank_save", group.clone())["error"]
            .as_str()
            .unwrap()
            .contains("Employer, Job title, Start date")
    );
    group["fields"] = json!({"employer":"Sample","job_title":"Intern","start_date":"2025-01"});
    let saved = rpc(&db, "a", "resume_bank_save", group);
    let private = saved["sources"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["editable"] == true)
        .unwrap();
    assert_eq!(private["revision"], 1);
    let selection = json!([{"id":private["id"],"revision":1,"record_ids":["r0"]}]);
    let args = json!({"id":"resume","revision":1,"selection":selection});
    assert_eq!(
        rpc(&db, "a", "resume_bank_select", args.clone())["resumes"][0]["selection"],
        selection
    );
    assert_eq!(
        rpc(&db, "a", "resume_bank_select", args)["error"],
        "Resume changed. Reload before choosing experience."
    );
    assert_eq!(
        rpc(&db, "b", "resume_bank", json!({}))["sources"],
        json!([])
    );
}
#[test]
fn interview_saved_role_questions_replay_correction_finish_and_isolation() {
    let db = open();
    db.execute_batch(
        "CREATE TABLE accounts(id TEXT PRIMARY KEY); INSERT INTO accounts VALUES('a');",
    )
    .unwrap();
    crate::account::init(&db).unwrap();
    crate::jobs::init(&db).unwrap();
    crate::resumes::init(&db).unwrap();
    let job = json!({"demo":false,"resume_id":"","job_id":"example","job":{"id":"example","title":"Software engineer","description":"Build software with Python. Collaborate with stakeholders."}});
    db.execute(
        "INSERT INTO job_records VALUES ('a','application','role',?)",
        [job],
    )
    .unwrap();
    let facts = json!([{"key":"resume.example.projects.1","value":"Project: Maps","verified":true,"source":"User verified"}]);
    db.execute(
        "INSERT INTO account_preferences(owner,policy,facts) VALUES ('a','{}',?)",
        [facts],
    )
    .unwrap();
    let a = json!({"application_id":"role","client_id":"start"});
    let p = rpc(&db, "a", "interview_create", a.clone());
    assert_eq!(p["data"]["questions"].as_array().unwrap().len(), 3);
    assert!(
        p["data"]["questions"][1]["question"]
            .as_str()
            .unwrap()
            .contains("Maps")
    );
    assert_eq!(rpc(&db, "a", "interview_create", a), p);
    let key = &p["id"];
    let args = json!({"id":key,"revision":0,"answer":"Saved text","client_id":"answer-1"});
    let answered = rpc(&db, "a", "interview_answer", args.clone());
    assert_eq!(answered["data"]["turns"][0]["original"], "Saved text");
    assert_eq!(answered["data"]["pending"], answered["run"]["id"]);
    assert_eq!(answered["run"]["status"], "queued");
    assert_eq!(rpc(&db, "a", "interview_answer", args), answered);
    let revised = rpc(
        &db,
        "a",
        "interview_correct",
        json!({"id":key,"revision":1,"index":0,"answer":"Edited text"}),
    );
    assert_eq!(
        revised["data"]["turns"][0]["previous"],
        json!(["Saved text"])
    );
    assert_eq!(
        rpc(
            &db,
            "a",
            "interview_continue",
            json!({"id":key,"revision":2,"action":"finish"})
        )["data"]["status"],
        "finished"
    );
    assert_eq!(
        rpc(&db, "b", "interview_get", json!({"id":key}))["error"],
        "Interview session not found."
    );
}
#[test]
fn practice_attempt_ranking_deletion_and_replay() {
    let db = open();
    db.execute_batch(
        "CREATE TABLE accounts(id TEXT PRIMARY KEY); INSERT INTO accounts VALUES ('a'),('b');",
    )
    .unwrap();
    let key = "lib-proud";
    let args = json!({"question_id":key,"client_id":"typed","answer":" Notes ","duration":3601,"video_id":"local"});
    let created = rpc(&db, "a", "practice_attempt_create", args.clone());
    assert_eq!(created["transcript"], "Notes");
    assert_eq!(created["duration"], 3600.0);
    assert_eq!(created["status"], "queued");
    assert_eq!(created["run"]["step"], "coach");
    assert_eq!(rpc(&db, "a", "practice_attempt_create", args), created);
    let id = &created["id"];
    let snapshot = json!({"problem_id":key,"language":"","answer":"Notes"});
    rpc(
        &db,
        "a",
        "prep_save_coaching",
        json!({"id":id,"submission":{"revision":0,"key":"scored","data":snapshot,"feedback":{"text":"Good.\nSCORES\nSpecificity: 4/4\nOwnership: 3/4\nStructure: 2/4\nReflection: 3/4"}}}),
    );
    let scored = rpc(&db, "a", "practice_attempt_get", json!({"id":id}));
    assert_eq!(scored["score"], 75);
    assert_eq!(scored["feedback"], "Good.");
    assert_eq!(
        rpc(&db, "a", "practice_attempts", json!({"question_id":key}))["attempts"][0],
        scored
    );
    assert_eq!(
        rpc(&db, "b", "practice_attempt_delete", json!({"id":id}))["error"],
        "Practice attempt not found."
    );
    assert_eq!(
        rpc(&db, "a", "practice_attempt_delete", json!({"id":id}))["deleted"],
        true
    );
}

#[test]
fn supporting_document_roundtrips_and_is_removed_with_owner() {
    let db = open();
    let v = rpc(
        &db,
        "a",
        "resume_bank_save",
        json!({"name":"Project","source":"My notes","entry_type":"other","fields":{},"records":[{"id":"r0","kind":"bullet","text":"Example"}],"confirm":true}),
    );
    let id = &v["sources"][0]["id"];
    // Minimal synthetic DOCX containing a single paragraph.
    let content = "UEsDBBQAAAAIAA0mcl00ueTgdAAAAJkAAAARAAAAd29yZC9kb2N1bWVudC54bWxFzjEKwzAMBdCrlBygCh06GNdbD+LabhKwLCG7OLl9o2TI8j4fIfi2m0jhh6m024q5VNNfw9waG4Aa5oS+3olT2W9fEvRtrzJBJ4ksFFKtS5kww2Mcn4B+KYOz3XwobpqsiNLce/XIOVnQosohH54PcI1xf1BLAQIUABQAAAAIAA0mcl00ueTgdAAAAJkAAAARAAAAAAAAAAAAAACAAQAAAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAAAQABAD8AAACjAAAAAAA=";
    let args = json!({"id":id,"revision":1,"name":"example.docx","content":content});
    assert_eq!(
        rpc(&db, "b", "resume_bank_attachment_save", args.clone())["error"],
        "Memory bank entry not found."
    );
    let changed = rpc(&db, "a", "resume_bank_attachment_save", args.clone());
    assert_eq!(changed["sources"][0]["revision"], 2);
    assert_eq!(changed["sources"][0]["confirmed"], false);
    assert!(rpc(&db, "a", "resume_bank_attachment_save", args)["error"].is_string());
    let read = rpc(&db, "a", "resume_bank_attachment", json!({"id":id}));
    assert_eq!(read["content"], content);
    assert_eq!(
        export(&db, "a").unwrap()["bank"][0]["supporting_document"],
        read
    );
    delete_owner(&db, "a").unwrap();
    assert!(rpc(&db, "a", "resume_bank_attachment", json!({"id":id}))["error"].is_string());
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM career_files", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
}
#[test]
fn unchanged_contact_edit_skips_write_and_real_edits_preserve_opt_out() {
    let db = open();
    let owner = "a";
    let saved = rpc(
        &db,
        owner,
        "agent_save_contact",
        json!({"data":{"name":"Pat","selected":true}}),
    );
    let id = &saved["contacts"][0]["id"];
    let stopped = rpc(&db, owner, "agent_stop_contact", json!({"id":id}));
    let before = db.total_changes();
    let replay = rpc(
        &db,
        owner,
        "agent_save_contact",
        json!({"id":id,"data":{"name":" Pat ","selected":true,"stopped":false}}),
    );
    assert_eq!(replay, stopped);
    assert_eq!(db.total_changes(), before);
    let changed = rpc(
        &db,
        owner,
        "agent_save_contact",
        json!({"id":id,"data":{"name":"Pat","company":"Stack","selected":false,"stopped":false}}),
    );
    assert!(db.total_changes() > before);
    assert_eq!(changed["contacts"][0]["company"], "Stack");
    assert_eq!(changed["contacts"][0]["selected"], false);
    assert_eq!(changed["contacts"][0]["stopped"], true);
}
#[test]
fn owning_recording_is_required_to_attach_and_practice_deletion_removes_audio() {
    let db = open();
    db.execute_batch(
        "CREATE TABLE accounts(id TEXT PRIMARY KEY); INSERT INTO accounts VALUES ('a'),('b');",
    )
    .unwrap();
    crate::recording::init(&db).unwrap();
    let recovered = json!({"id":"owned","status":"completed","original_transcript":"Device original","transcript":"Reviewed correction","revision":2});
    db.execute(
        "INSERT INTO recordings VALUES ('owned','a','client-token-001',x'01',1,1,?,x'01')",
        [recovered],
    )
    .unwrap();
    let args = json!({"question_id":"lib-proud","client_id":"practice-1","answer":"Reviewed correction","recording_id":"owned"});
    assert_eq!(
        rpc(&db, "b", "practice_attempt_create", args.clone())["error"],
        "Recording not found."
    );
    let p = rpc(&db, "a", "practice_attempt_create", args);
    assert_eq!(p["recording_id"], "owned");
    let session = json!({"id":"i","revision":0,"data":{"job":{},"resume_id":"","facts":[],"analysis":{},"questions":[{"question":"Tell me about your work.","evidence":[],"kind":"experience"}],"turns":[],"status":"active","pending":"","coaching":{}}});
    put(&db, "a", "interview", "i", &session).unwrap();
    put(&db, "b", "interview", "i", &session).unwrap();
    let args = json!({"id":"i","revision":0,"answer":"Reviewed correction","recording_id":"owned","client_id":"answer-1"});
    assert_eq!(
        rpc(&db, "b", "interview_answer", args.clone())["error"],
        "Recording not found."
    );
    let turn = &rpc(&db, "a", "interview_answer", args)["data"]["turns"][0];
    assert_eq!(turn["original"], "Device original");
    assert_eq!(turn["answer"], "Reviewed correction");
    assert_eq!(turn["recording_id"], "owned");
    assert_eq!(
        rpc(&db, "a", "practice_attempt_delete", json!({"id":p["id"]}))["deleted"],
        true
    );
    assert!(crate::recording::get(&db, "a", "owned").unwrap().is_none());
}
