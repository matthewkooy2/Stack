use axum::http::StatusCode;
use serde_json::{Value, json};

// Required inputs in the released Jac function signatures, in declaration order.
pub fn missing(name: &str, args: &Value) -> Option<crate::Response> {
    let required: &[&str] = match name {
        "prep_for_application" | "score_resume" => &["application_id"],
        "interview_create" => &["application_id", "client_id"],
        "agent_google_start" | "agent_google_start_native" => &["capabilities"],
        "transcription_upload" => &["client_id", "content"],
        "agent_import_contacts" => &["content"],
        "agent_save_contact" => &["data"],
        "agent_register_push" | "agent_remove_push" => &["device_token"],
        "agent_save_facts" => &["facts"],
        "save_timeline" => &["graduation_month"],
        "agent_browser_subscribe"
        | "agent_cancel"
        | "agent_continue_tailoring"
        | "agent_disconnect"
        | "agent_dismiss"
        | "agent_extract_resume"
        | "agent_model_logs"
        | "agent_respond"
        | "agent_retry"
        | "agent_run"
        | "agent_stop_contact"
        | "agent_traces"
        | "check_tailored_resume"
        | "delete_tailored_resume"
        | "get_import_status"
        | "get_job"
        | "gmail_scan_dismiss"
        | "interview_get"
        | "mark_application_submitted"
        | "practice_attempt_delete"
        | "practice_attempt_get"
        | "prep_get"
        | "prep_live"
        | "read_resume"
        | "read_resume_source"
        | "read_tailored_resume"
        | "resume_bank_attachment"
        | "transcription_audio"
        | "transcription_get" => &["id"],
        "agent_browser_control" | "change_reminder" | "change_resume" | "transcription_action" => {
            &["id", "action"]
        }
        "agent_resolve_event" => &["id", "application_id", "status"],
        "prep_coach" => &["id", "data"],
        "transcription_transfer_complete" => &["id", "elapsed_ms"],
        "agent_browser" => &["id", "event"],
        "resume_transfer_complete" => &["id", "job_id", "elapsed_ms"],
        "retry_resume_processing" => &["id", "kind"],
        "upload_resume_source" => &["id", "name", "content"],
        "save_application" => &["id", "notes"],
        "agent_reconcile" => &["id", "outcome", "evidence"],
        "agent_feedback" => &["id", "output_version", "rating", "note"],
        "select_application_resume" => &["id", "resume_id"],
        "interview_continue" | "resume_bank_delete" => &["id", "revision"],
        "interview_answer" => &["id", "revision", "answer", "client_id"],
        "prep_save" => &["id", "revision", "data"],
        "interview_correct" => &["id", "revision", "index", "answer"],
        "resume_bank_attachment_save" => &["id", "revision", "name", "content"],
        "resume_save_records" => &["id", "revision", "records"],
        "resume_bank_select" => &["id", "revision", "selection"],
        "resume_save_details" => &["id", "revision", "values"],
        "save_contact" => &["id", "saved", "draft", "notes"],
        "agent_approve" => &["id", "step", "review_hash"],
        "prep_save_coaching" => &["id", "submission"],
        "save_reminder" => &["id", "target_type", "target_id", "title", "due_at"],
        "use_resume_template" => &["id", "template"],
        "practice_profile" => &["industry"],
        "swipe" => &["job_id", "action"],
        "agent_start" => &["kind", "target_id"],
        "upload_resume" => &["name", "content"],
        "save_profile" => &["name", "role", "location", "mode", "notifications"],
        "resume_bank_save" => &["name", "source", "records"],
        "agent_save_policy" => &["policy"],
        "prep_create" => &["problem_id"],
        "save_search" => &["query", "filters"],
        "practice_attempts" => &["question_id"],
        "practice_attempt_create" => &["question_id", "client_id", "answer"],
        "agent_save_model" => &["selection"],
        "gmail_scan_start" => &["since"],
        "agent_google_finish" => &["state", "code"],
        "import_job_url" => &["url"],
        _ => &[],
    };
    if required.iter().all(|key| args.get(*key).is_some()) {
        return None;
    }
    let detail: Vec<_> = required
        .iter()
        .filter(|key| args.get(**key).is_none())
        .map(|key| json!({"type":"missing","loc":["body",key],"msg":"Field required"}))
        .collect();
    Some((StatusCode::UNPROCESSABLE_ENTITY, json!({"detail":detail})))
}
