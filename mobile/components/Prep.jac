import from "@jac/mobui" { View, Text, Pressable }
import from "../device.js" { Icon }
import from ..theme { s }
import from .UI { Button, Chip }
import from .Practice { Practice }
import from .Transcription { Transcription }

glob QUESTIONS: list[dict[str, any]] = [
    {"id":"two-sum", "track":"Technical", "title":"Find a pair", "topic":"Arrays & hash maps", "time":"15 min", "prompt":"Given an array of integers and a target, return the indices of two distinct elements whose sum equals the target. What should happen if there is no matching pair?", "steps":["Clarify whether there is exactly one solution and whether values can repeat.","Walk through [2, 7, 11, 15] with target 9 before writing code.","Explain a simple solution, then improve it."], "guide":"Keep a map from previously seen values to their indices. For each value x, look for target − x before adding x to the map. Checking first prevents reusing the same index. Expected time: O(n); extra space: O(n).", "check":"Test duplicate values, negative numbers, and no solution. Explain why two nested loops take O(n²)."},
    {"id":"brackets", "track":"Technical", "title":"Balanced brackets", "topic":"Stacks", "time":"15 min", "prompt":"A string contains only (, ), [, ], {, and }. Determine whether every opening bracket is closed in the correct order.", "steps":["Define what should happen for an empty string.","Compare the examples ([]), ([)], and ((.","Describe what you need to remember as you scan."], "guide":"Push opening brackets onto a stack. For each closing bracket, reject an empty stack or a mismatched top; otherwise pop. Accept only if the stack is empty at the end. Time: O(n); worst-case extra space: O(n).", "check":"Cover empty input, a closing bracket first, nested pairs, and leftover opening brackets."},
    {"id":"debugging", "track":"Technical", "title":"Debug a slow endpoint", "topic":"Debugging & backend basics", "time":"10 min", "prompt":"A job-search endpoint gets much slower as the number of saved jobs grows. How would you investigate it before changing the code?", "steps":["Ask about the data size, latency, and when the slowdown began.","Separate database time, application work, and network time.","Choose a measurement that would support your hypothesis."], "guide":"Reproduce the slowdown with representative data and inspect timing or traces. Check query count, query plans, indexes, and repeated work. Pick a fix supported by measurements, such as avoiding N+1 queries or adding pagination, then compare latency and verify correctness.", "check":"Explain how you would avoid exposing personal data in logs and how you would detect a regression."},
    {"id":"project", "track":"Behavioral", "title":"Tell your project story", "topic":"Ownership", "time":"5 min", "prompt":"Tell me about a project you are proud of. What did you personally contribute, and what did you learn?", "steps":["Situation: give just enough context to explain the problem.","Task and action: name your responsibility and the choices you made.","Result: explain the outcome and one lesson you would carry forward."], "guide":"Use a class, personal, volunteer, or internship project. Distinguish your work from the team's work. Describe a concrete tradeoff and an honest outcome; you do not need invented metrics to tell a strong story.", "check":"Could someone unfamiliar with the project understand the problem, your contribution, and the result in about two minutes?"},
    {"id":"disagreement", "track":"Behavioral", "title":"Work through disagreement", "topic":"Collaboration", "time":"5 min", "prompt":"Tell me about a time you disagreed with a teammate. How did you reach a decision?", "steps":["Explain the shared goal and the competing views without assigning blame.","Describe how you listened, gathered evidence, or tested an idea.","Share the decision, the outcome, and what you learned."], "guide":"Use the STAR structure: Situation, Task, Action, Result. Focus on what you did to make the discussion productive. A strong answer can include changing your own mind when the evidence supported it.", "check":"Does your answer show respect, a specific action, and a clear resolution rather than just saying you compromised?"},
    {"id":"setback", "track":"Behavioral", "title":"Learn from a setback", "topic":"Growth", "time":"5 min", "prompt":"Describe a mistake or setback. What did you do next, and what changed afterward?", "steps":["Choose a real example and briefly explain your responsibility.","Describe how you communicated and addressed the immediate problem.","Explain the change you made to prevent the same issue."], "guide":"Be specific and take responsibility for your part. Show how you asked for help, recovered, and adjusted your process. Keep the emphasis on learning and subsequent behavior rather than a perfect ending.", "check":"Can you point to a concrete change in how you now test, plan, communicate, or ask for feedback?"}
];

def:pub Prep(owner: str = "", runs: list[dict[str, any]] = [], features: list[dict[str, any]] = [], onOpenTask: any = None, onNavigate: any = None) -> JsxElement {
    has track: str = "Technical", current: int = 0, revealed: bool = False;

    def changeTrack(value: str) -> None { track=value; current=0; revealed=False; }
    def nextQuestion -> None {
        current=(current+1) % len([q for q in QUESTIONS if q["track"]==track]);
        revealed=False;
    }

    <View style={{gap:22}}>
        <Transcription key={owner} owner={owner}/>
        <Practice runs={runs} features={features} onOpenTask={onOpenTask} onNavigate={onNavigate}/>
        <View style={{gap:7}}>
            <Text style={s.eyebrow}>A LITTLE PRACTICE. MORE CONFIDENCE.</Text>
            <Text style={s.title}>Show up ready.</Text>
            <Text style={s.body}>Build your problem-solving skills and learn to tell your story.</Text>
        </View>
        <View style={s.wrap}>
            {[<Chip key={t} label={t} active={track==t} onPress={lambda { changeTrack(t); }}/> for t in ["Technical","Behavioral"]]}
        </View>
        <View style={s.hero}>
            <View style={s.row}><Icon name={"code" if track=="Technical" else "conversation"} color="#3765E8"/><Text style={[s.heading,{flex:1}]}>{"Think it through." if track=="Technical" else "Make your experience count."}</Text></View>
            <Text style={s.body}>{"Clarify the problem, explain your approach, and test the edge cases." if track=="Technical" else "Practice a clear, honest answer using Situation, Task, Action, and Result."}</Text>
        </View>
        {[
            <View key={q["id"]} style={s.card}>
                <View style={s.wrap}><Chip label={q["topic"]}/><Chip label={q["time"]}/></View>
                <Text style={s.heading}>{q["title"]}</Text>
                <Text style={[s.strong,{lineHeight:24}]}>{q["prompt"]}</Text>
                <View style={s.line}/>
                <Text style={s.eyebrow}>YOUR PRACTICE PLAN</Text>
                {[<Text key={step} style={s.body}>• {step}</Text> for step in q["steps"]]}
                <Text style={s.small}>Try answering out loud before opening the guide.</Text>
                {<View style={s.hero}><Text style={s.strong}>{"An approach to consider" if track=="Technical" else "Coaching notes"}</Text><Text style={s.body}>{q["guide"]}</Text><Text style={s.strong}>Check your answer</Text><Text style={s.body}>{q["check"]}</Text></View> if revealed else <View/>}
                <Button label={"Hide guide" if revealed else "Show practice guide"} onPress={lambda { revealed=not revealed; }} secondary={True}/>
                <Button label="Next question" onPress={nextQuestion} icon="next"/>
            </View>
            for q in [q for q in QUESTIONS if q["track"]==track][current:current+1]
        ]}
        <View style={s.mutedBox}><Text style={s.small}>Self-guided practice for entry-level SWE interviews. The guides below are self-guided and are not scored.</Text></View>
    </View>
}
