import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText }
import from ..theme { s }
import from .UI { Button, Field, Chip }

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
    <View style={{gap:10}}>
        <Text style={s.heading}>Agent Feedback</Text>
        <View style={s.wrap}>{[<Chip key={value} label={value.title()} active={rating==value} onPress={lambda { rating=value;message=""; }}/> for value in ["good","mixed","bad"]]}</View>
        <Field label="What worked or needs improvement?" value={note} onChange={lambda (value: str) { note=value;message=""; }} multiline={True}/>
        <Button label="Save agent feedback" icon="conversation" disabled={busy or not rating or not note.strip()} onPress={save}/>
        {<Text style={s.small}>{message}</Text> if message else <View/>}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
    </View>
}
