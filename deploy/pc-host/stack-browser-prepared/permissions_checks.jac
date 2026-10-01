"""Regression tests of the existing shared functions, with synthetic policies only."""
import from agents.contracts { authorize, validate_policy, model_access, workflow_steps, EXTERNAL, reserve_cents }
import from agents.experience { REVIEWED }
import time;

def rules() -> dict[str, any] {
    return validate_policy({
        'enabled': True, 'actions': ['model'], 'expires_at': time.time()+86400
    });
}
def local_model() -> dict[str, any] {
    return {'provider': 'codex-cli', 'local_cli_owner': '11111111111111111111111111111111', 'local_cli_daily_limit': 2};
}
test "read analysis and draft workflows retain model authorization" {
    p=rules();
    for kind in ['resume','prep','jobs','network','profile','linkedin'] {
        assert len(workflow_steps(kind,2))>0;
        authorize(p,'model');
        model_access(local_model(),'11111111111111111111111111111111');
    }
}
test "network draft is separate from sending" {
    assert workflow_steps('network',2)==['research','draft','send'];
    authorize(rules(),'model');
    with testraises(ValueError) { authorize(rules(),'send_email','person@example.test'); }
}
test "resume draft is separate from reviewed final output" {
    assert workflow_steps('resume',2)==['tailor','approve_resume'];
    assert 'approve_resume' in REVIEWED;
}
test "all external steps require review" {
    for step in EXTERNAL { assert step in REVIEWED; }
}
test "owner mismatch cannot borrow local model login" {
    with testraises(ValueError) { model_access(local_model(),'22222222222222222222222222222222'); }
}
test "model daily limits remain bounded" {
    for limit in [0,101] {
        c=local_model();c['local_cli_daily_limit']=limit;
        with testraises(ValueError) { model_access(c,'11111111111111111111111111111111'); }
    }
}
test "paid provider without budgets remains disabled" {
    c={'provider':'openai','model':'synthetic','monthly_cents':0,'user_monthly_cents':0,'input_cents_per_million':0,'output_cents_per_million':0};
    with testraises(ValueError) { model_access(c,'11111111111111111111111111111111'); }
}
test "all unselected external actions are denied" {
    for action in EXTERNAL.values() { with testraises(ValueError) { authorize(rules(),action,'example.test'); } }
}
test "selected external action still needs a user daily limit and destination" {
    p=rules();p['actions']=['send_email'];p['domains']=['example.test'];
    with testraises(ValueError) { authorize(p,'send_email','person@example.test'); }
    p['daily_limits']={'send_email':1};
    authorize(p,'send_email','person@example.test');
    with testraises(ValueError) { authorize(p,'send_email','person@outside.test'); }
}
test "expired permissions and unknown actions fail closed" {
    p=rules();p['expires_at']=0;
    with testraises(ValueError) { authorize(p,'model'); }
    with testraises(ValueError) { authorize(rules(),'unknown_external_action'); }
    with testraises(ValueError) { validate_policy({'actions':['unknown_external_action']}); }
}
test "application stages retain explicit external review" {
    steps=workflow_steps('application',2);
    assert 'fill' in steps and 'submit' in steps;
    assert 'fill' in REVIEWED and 'submit' in REVIEWED;
}
test "calendar remains reviewed and unknown workflows are refused" {
    assert workflow_steps('calendar',2)==['calendar'];assert 'calendar' in REVIEWED;
    with testraises(KeyError) { workflow_steps('unknown_workflow',2); }
}
