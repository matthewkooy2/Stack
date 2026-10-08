# Shared native view source, migrated from prototype/mock-interview.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub mock_interview_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="InterviewFeedback" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub mock_interview_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="InterviewFeedback" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub mock_interview_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub mock_interview_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="interview-self" spec={v["s0"]}>
        <StackComponent kind="UserRound" variant="" spec={v["s1"]}></StackComponent>
        <StackText kind="small" variant="" spec={v["s2"]}>{"You · Preview"}</StackText></StackLayout>
    );
}

def:pub mock_interview_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="interview-transcript" spec={v["s0"]}>
        <StackLayout kind="span" variant="" spec={v["s1"]}>{"Sample live transcript"}</StackLayout>
        <StackText kind="p" variant="" spec={v["s2"]}>{v["s3"]}</StackText></StackLayout>
    );
}

def:pub mock_interview_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="interview-ready-actions" spec={v["s0"]}>
        <StackButton kind="button" variant="interview-repeat" spec={v["s1"]}>
            <StackComponent kind="RotateCcw" variant="" spec={v["s2"]}></StackComponent>{" Repeat question"}</StackButton>
        <StackButton kind="button" variant="sheet-primary interview-primary" spec={v["s3"]}>
            <StackComponent kind="Mic" variant="" spec={v["s4"]}></StackComponent>{" Start answer"}</StackButton></StackLayout>
    );
}

def:pub mock_interview_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackButton kind="button" variant="sheet-primary interview-primary recording" spec={v["s0"]}>
        <StackComponent kind="Square" variant="" spec={v["s1"]}></StackComponent>{" Finish answer"}</StackButton>
    <StackText kind="p" variant="interview-hint" spec={v["s2"]}>{"Answering · "}{v["s3"]}</StackText></StackFragment>
    );
}

def:pub mock_interview_10(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="interview-transcript" spec={v["s0"]}>
        <StackLayout kind="span" variant="" spec={v["s1"]}>{"Sample answer"}</StackLayout>
        <StackText kind="p" variant="" spec={v["s2"]}>{v["s3"]}</StackText></StackLayout>
    );
}

def:pub mock_interview_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="interview-review" spec={v["s0"]}>
        <StackButton kind="button" variant="interview-review-toggle" spec={v["s1"]}>
            <StackComponent kind="AlignLeft" variant="" spec={v["s2"]}></StackComponent>{" "}{v["s3"]}</StackButton>{v["s4"]}
        <StackLayout kind="div" variant="interview-review-actions" spec={v["s5"]}>
            <StackButton kind="button" variant="interview-retry" spec={v["s6"]}>
                <StackComponent kind="RotateCcw" variant="" spec={v["s7"]}></StackComponent>{" Try again"}</StackButton>
            <StackButton kind="button" variant="sheet-primary" spec={v["s8"]}>{"Done "}
                <StackComponent kind="Check" variant="" spec={v["s9"]}></StackComponent></StackButton></StackLayout></StackLayout>
    );
}

def:pub mock_interview_11(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="jobs-sheet-backdrop" spec={v["s0"]}>
        <StackLayout kind="section" variant="jobs-sheet interview-settings" spec={v["s1"]}>
            <StackLayout kind="div" variant="sheet-handle" spec={v["s2"]}></StackLayout>
            <StackButton kind="button" variant="sheet-close" spec={v["s3"]}>
                <StackComponent kind="X" variant="" spec={v["s4"]}></StackComponent></StackButton>
            <StackText kind="h2" variant="" spec={v["s5"]}>{"Interview settings"}</StackText>
            <StackButton kind="button" variant="interview-setting-row" spec={v["s6"]}>
                <StackLayout kind="span" variant="" spec={v["s7"]}>
                    <StackText kind="strong" variant="" spec={v["s8"]}>{"Camera preview"}</StackText>
                    <StackText kind="small" variant="" spec={v["s9"]}>{"See yourself while answering"}</StackText></StackLayout>
                <StackLayout kind="i" variant="" spec={v["s10"]}></StackLayout></StackButton>
            <StackButton kind="button" variant="interview-setting-row" spec={v["s11"]}>
                <StackLayout kind="span" variant="" spec={v["s12"]}>
                    <StackText kind="strong" variant="" spec={v["s13"]}>{"Live transcript"}</StackText>
                    <StackText kind="small" variant="" spec={v["s14"]}>{"Follow your answer as you speak"}</StackText></StackLayout>
                <StackLayout kind="i" variant="" spec={v["s15"]}></StackLayout></StackButton>
            <StackText kind="p" variant="application-detail-hint" spec={v["s16"]}>{"Simulated media for this prototype. Nothing is recorded."}</StackText></StackLayout></StackLayout>
    );
}

def:pub mock_interview_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="article" variant="mock-interview interview-focused" spec={v["s0"]}>
        <StackLayout kind="header" variant="interview-toolbar" spec={v["s1"]}>
            <StackButton kind="button" variant="" spec={v["s2"]}>
                <StackComponent kind="ArrowLeft" variant="" spec={v["s3"]}></StackComponent></StackButton>
            <StackLayout kind="span" variant="" spec={v["s4"]}>{v["s5"]}</StackLayout>
            <StackButton kind="button" variant="" spec={v["s6"]}>
                <StackComponent kind="SlidersHorizontal" variant="" spec={v["s7"]}></StackComponent></StackButton></StackLayout>
        <StackLayout kind="div" variant="" spec={v["s8"]}>
            <StackLayout kind="div" variant="interviewer-orb" spec={v["s9"]}>
                <StackComponent kind="UserRound" variant="" spec={v["s10"]}></StackComponent></StackLayout>
            <StackLayout kind="div" variant="interviewer-wave" spec={v["s11"]}>{v["s12"]}</StackLayout>
            <StackLayout kind="span" variant="" spec={v["s13"]}>{v["s14"]}</StackLayout>
            <StackText kind="p" variant="interview-caption" spec={v["s15"]}>{v["s16"]}</StackText>{v["s17"]}
            <StackText kind="small" variant="interview-media-label" spec={v["s18"]}>{"Simulated video"}</StackText></StackLayout>{v["s19"]}{v["s20"]}{v["s21"]}</StackLayout>
    );
}
