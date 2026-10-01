import from "./transport.js" { rpc, errorText }

def:pub AgentFeedback(runId: str, outputVersion: str) -> JsxElement {
    has rating: str = "", note: str = "", busy: bool = False, message: str = "", error: str = "";
    async def save -> None {
        busy=True;error="";message="";
        try {
            await rpc("agent_feedback",{"id":runId,"output_version":outputVersion,"rating":rating,"note":note});
            note="";rating="";message="Feedback saved.";
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    <div>
        <h3>Agent Feedback</h3>
        <label>Rating<select value={rating} onChange={lambda (e: any) { rating=e.target.value;message=""; }}><option value="">Choose a rating</option>{[<option key={value} value={value}>{value.title()}</option> for value in ["good","mixed","bad"]]}</select></label>
        <label>What worked or needs improvement?<textarea maxLength={4000} value={note} onChange={lambda (e: any) { note=e.target.value;message=""; }}/></label>
        <button disabled={busy or not rating or not note.strip()} onClick={save}>Save agent feedback</button>
        {<p role="status">{message}</p> if message else <span/>}{<p role="alert">{error}</p> if error else <span/>}
    </div>
}
