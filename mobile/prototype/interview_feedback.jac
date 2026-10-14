# Shared native view source, migrated from prototype/interview-feedback.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub interview_feedback_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="jobs-loading-announcement" spec={v["s0"]}>{"Reviewing your answer"}</StackLayout>
    );
}

def:pub interview_feedback_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="" spec={v["s0"]}>
        <StackLayout kind="span" variant="" spec={v["s1"]}>{v["s2"]}</StackLayout>
        <StackLayout kind="div" variant="" spec={v["s3"]}>
            <StackLayout kind="i" variant="" spec={v["s4"]}></StackLayout></StackLayout>
        <StackText kind="strong" variant="" spec={v["s5"]}>{v["s6"]}</StackText></StackLayout>
    );
}

def:pub interview_feedback_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="feedback-metrics" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub interview_feedback_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="feedback-transcript" spec={v["s0"]}>
        <StackText kind="small" variant="" spec={v["s1"]}>{"Demo transcript · Not recorded speech"}</StackText>
        <StackText kind="p" variant="" spec={v["s2"]}>{v["s3"]}</StackText></StackLayout>
    );
}

def:pub interview_feedback_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="article" variant="" spec={v["s0"]}>
        <StackLayout kind="header" variant="interview-toolbar" spec={v["s1"]}>
            <StackButton kind="button" variant="" spec={v["s2"]}>
                <StackComponent kind="ArrowLeft" variant="" spec={v["s3"]}></StackComponent></StackButton>
            <StackLayout kind="span" variant="" spec={v["s4"]}>{"Feedback"}</StackLayout>
            <StackLayout kind="span" variant="" spec={v["s5"]}></StackLayout></StackLayout>
        <StackScroll kind="main" variant="feedback-content" spec={v["s6"]}>{v["s7"]}
            <StackText kind="p" variant="feedback-question" spec={v["s8"]}>{v["s9"]}</StackText>
            <StackLayout kind="div" variant="feedback-score" spec={v["s10"]}>
                <StackText kind="strong" variant="" spec={v["s11"]}>{v["s12"]}
                    <StackText kind="small" variant="" spec={v["s13"]}>{"/100"}</StackText></StackText>
                <StackLayout kind="span" variant="" spec={v["s14"]}>{"A solid foundation"}</StackLayout></StackLayout>
            <StackText kind="p" variant="feedback-demo" spec={v["s15"]}>{v["s16"]}</StackText>
            <StackButton kind="button" variant="feedback-disclosure" spec={v["s17"]}>{"Score breakdown"}
                <StackComponent kind="ChevronDown" variant="" spec={v["s18"]}></StackComponent></StackButton>{v["s19"]}
            <StackLayout kind="section" variant="feedback-coaching" spec={v["s20"]}>
                <StackLayout kind="span" variant="feedback-label" spec={v["s21"]}>{"What worked"}</StackLayout>
                <StackText kind="h2" variant="" spec={v["s22"]}>{v["s23"]}</StackText>
                <StackText kind="blockquote" variant="" spec={v["s24"]}>{v["s25"]}</StackText>
                <StackText kind="p" variant="" spec={v["s26"]}>{v["s27"]}</StackText></StackLayout>
            <StackLayout kind="section" variant="feedback-coaching" spec={v["s28"]}>
                <StackLayout kind="span" variant="feedback-label" spec={v["s29"]}>{"Focus next"}</StackLayout>
                <StackText kind="h2" variant="" spec={v["s30"]}>{v["s31"]}</StackText>
                <StackText kind="p" variant="" spec={v["s32"]}>{v["s33"]}</StackText></StackLayout>
            <StackLayout kind="div" variant="feedback-next" spec={v["s34"]}>
                <StackComponent kind="RotateCcw" variant="" spec={v["s35"]}></StackComponent>
                <StackText kind="p" variant="" spec={v["s36"]}>{v["s37"]}</StackText></StackLayout>
            <StackButton kind="button" variant="feedback-disclosure" spec={v["s38"]}>{"Your transcript "}
                <StackComponent kind="ChevronDown" variant="" spec={v["s39"]}></StackComponent></StackButton>{v["s40"]}</StackScroll>
        <StackLayout kind="footer" variant="feedback-actions" spec={v["s41"]}>
            <StackButton kind="button" variant="interview-repeat" spec={v["s42"]}>
                <StackComponent kind="RotateCcw" variant="" spec={v["s43"]}></StackComponent>{" Try again"}</StackButton>
            <StackButton kind="button" variant="sheet-primary" spec={v["s44"]}>{"Done "}
                <StackComponent kind="Check" variant="" spec={v["s45"]}></StackComponent></StackButton></StackLayout></StackLayout>
    );
}
