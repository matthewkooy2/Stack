# Shared native view source, migrated from prototype/application-task.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub application_task_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="application-error" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub application_task_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub application_task_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{"This listing is closed."}</StackText>
    );
}

def:pub application_task_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="h3" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    <StackText kind="p" variant="" spec={v["s2"]}>{v["s3"]}</StackText>
    <StackLayout kind="ol" variant="application-steps" spec={v["s4"]}>{v["s5"]}</StackLayout>
    <StackButton kind="button" variant="sheet-primary" spec={v["s6"]}>{v["s7"]}</StackButton>{v["s8"]}</StackFragment>
    );
}

def:pub application_task_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="application-progress" spec={v["s0"]}>
        <StackText kind="strong" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackLayout kind="div" variant="application-placeholder" spec={v["s3"]}></StackLayout>
        <StackLayout kind="div" variant="application-placeholder short" spec={v["s4"]}></StackLayout></StackLayout>
    );
}

def:pub application_task_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="application-review" spec={v["s0"]}>
        <StackText kind="h4" variant="" spec={v["s1"]}>{"Original"}</StackText>
        <StackText kind="p" variant="" spec={v["s2"]}>{v["s3"]}</StackText>
        <StackText kind="h4" variant="" spec={v["s4"]}>{"Proposed"}</StackText>
        <StackText kind="p" variant="" spec={v["s5"]}>{v["s6"]}</StackText>
        <StackLayout kind="label" variant="application-checkbox" spec={v["s7"]}>
            <StackInput kind="input" variant="" spec={v["s8"]}></StackInput>{"Keep this change"}</StackLayout></StackLayout>
    );
}

def:pub application_task_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="h4" variant="" spec={v["s0"]}>{"Keep or reject each change"}</StackText>
    <StackText kind="p" variant="" spec={v["s1"]}>{"Sample wording only. Your original stays unchanged."}</StackText>{v["s2"]}
    <StackButton kind="button" variant="application-secondary" spec={v["s3"]}>{v["s4"]}{" proposed resume"}</StackButton>
    <StackButton kind="button" variant="sheet-primary" spec={v["s5"]}>{"Approve resume changes"}</StackButton>
    <StackButton kind="button" variant="application-secondary" spec={v["s6"]}>{"Review fit evidence"}</StackButton></StackFragment>
    );
}

def:pub application_task_11(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="label" variant="" spec={v["s0"]}>{v["s1"]}
        <StackInput kind="input" variant="" spec={v["s2"]}></StackInput></StackLayout>
    );
}

def:pub application_task_10(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="h4" variant="" spec={v["s0"]}>{"Your answers are needed"}</StackText>
    <StackText kind="p" variant="" spec={v["s1"]}>{"No answers are inferred. Confirm these before filling the form."}</StackText>{v["s2"]}
    <StackButton kind="button" variant="sheet-primary" spec={v["s3"]}>{"Save answers and resume"}</StackButton></StackFragment>
    );
}

def:pub application_task_13(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="" spec={v["s0"]}>
        <StackText kind="dt" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackText kind="dd" variant="" spec={v["s3"]}>{v["s4"]}</StackText></StackLayout>
    );
}

def:pub application_task_12(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="h4" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    <StackLayout kind="dl" variant="application-answer-list" spec={v["s2"]}>{v["s3"]}
        <StackLayout kind="div" variant="" spec={v["s4"]}>
            <StackText kind="dt" variant="" spec={v["s5"]}>{"Document"}</StackText>
            <StackText kind="dd" variant="" spec={v["s6"]}>{v["s7"]}{" · "}{v["s8"]}{" changes kept"}</StackText></StackLayout></StackLayout>
    <StackButton kind="button" variant="application-secondary" spec={v["s9"]}>{"Preview reviewed document"}</StackButton>
    <StackButton kind="button" variant="application-secondary" spec={v["s10"]}>{"Edit answers"}</StackButton>
    <StackLayout kind="label" variant="application-checkbox" spec={v["s11"]}>
        <StackInput kind="input" variant="" spec={v["s12"]}></StackInput>{v["s13"]}</StackLayout>
    <StackButton kind="button" variant="sheet-primary" spec={v["s14"]}>{v["s15"]}</StackButton>
    <StackButton kind="a" variant="application-text-link" spec={v["s16"]}>{"Apply myself in the browser"}</StackButton>
    <StackText kind="p" variant="application-muted" spec={v["s17"]}>{"Sample employer destination. Opening it does not mark this application as submitted."}</StackText></StackFragment>
    );
}

def:pub application_task_15(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="" spec={v["s0"]}>{"A matching LaTeX source or built-in format is needed. This preview can use a sample built-in format."}</StackText>
    <StackButton kind="button" variant="sheet-primary" spec={v["s1"]}>{"Use sample built-in format"}</StackButton></StackFragment>
    );
}

def:pub application_task_16(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="sheet-primary" spec={v["s0"]}>{"Reconnect simulated browser and retry"}</StackButton>
    );
}

def:pub application_task_14(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="application-error" spec={v["s0"]}>{v["s1"]}</StackText>{v["s2"]}
    <StackButton kind="a" variant="application-text-link" spec={v["s3"]}>{"Continue on the employer site"}</StackButton></StackFragment>
    );
}

def:pub application_task_17(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="application-error" spec={v["s0"]}>{v["s1"]}</StackText>
    <StackButton kind="button" variant="sheet-primary" spec={v["s2"]}>{"Retry from saved step"}</StackButton></StackFragment>
    );
}

def:pub application_task_18(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="application-error" spec={v["s0"]}>{v["s1"]}</StackText>
    <StackText kind="p" variant="" spec={v["s2"]}>{"There will be no automatic retry. This is a simulated outcome."}</StackText>
    <StackLayout kind="label" variant="" spec={v["s3"]}>{"What did you check?"}
        <StackInput kind="textarea" variant="" spec={v["s4"]}></StackInput></StackLayout>
    <StackButton kind="button" variant="sheet-primary" spec={v["s5"]}>{"Confirm it completed"}</StackButton>
    <StackButton kind="button" variant="application-secondary" spec={v["s6"]}>{"Nothing was sent — review again"}</StackButton></StackFragment>
    );
}

def:pub application_task_19(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="application-success" spec={v["s0"]}>{"Tailored version saved to Resume"}</StackText>
    <StackText kind="p" variant="" spec={v["s1"]}>{"Reviewed details are saved in Tailored. Open Files & checks to preview or download the PDF."}</StackText>
    <StackButton kind="button" variant="sheet-primary" spec={v["s2"]}>{"Open Tailored resumes"}</StackButton>
    <StackButton kind="button" variant="application-secondary" spec={v["s3"]}>{"Tailor again"}</StackButton></StackFragment>
    );
}

def:pub application_task_20(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="application-success" spec={v["s0"]}>{"Simulation complete"}</StackText>
    <StackText kind="p" variant="" spec={v["s1"]}>{"Receipt: "}{v["s2"]}</StackText>
    <StackText kind="p" variant="" spec={v["s3"]}>{"No employer was contacted. Your tracked stage remains "}{v["s4"]}{"."}</StackText>
    <StackButton kind="a" variant="sheet-primary" spec={v["s5"]}>{"Continue in browser"}</StackButton>
    <StackButton kind="button" variant="application-secondary" spec={v["s6"]}>{"Prepare again"}</StackButton></StackFragment>
    );
}

def:pub application_task_21(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="ApplicationDocument" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub application_task_22(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>
        <StackText kind="strong" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackLayout kind="span" variant="" spec={v["s3"]}>{v["s4"]}</StackLayout></StackText>
    );
}

def:pub application_task_23(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="application-secondary" spec={v["s0"]}>{"Cancel task"}</StackButton>
    );
}

def:pub application_task_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="div" variant="application-task-heading" spec={v["s0"]}>
        <StackText kind="h3" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackLayout kind="span" variant="application-pill" spec={v["s3"]}>{v["s4"]}</StackLayout></StackLayout>
    <StackText kind="p" variant="application-muted" spec={v["s5"]}>{v["s6"]}{" · "}{v["s7"]}</StackText>{v["s8"]}{v["s9"]}{v["s10"]}{v["s11"]}{v["s12"]}{v["s13"]}{v["s14"]}{v["s15"]}{v["s16"]}
    <StackDisclosure kind="details" variant="" spec={v["s17"]}>
        <StackSummary kind="summary" variant="" spec={v["s18"]}>{"Task history"}</StackSummary>
        <StackLayout kind="ol" variant="application-history" spec={v["s19"]}>{v["s20"]}</StackLayout></StackDisclosure>{v["s21"]}</StackFragment>
    );
}

def:pub application_task_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackComponent kind="TaskScenarios" variant="" spec={v["s0"]}></StackComponent>
    <StackText kind="p" variant="application-muted" spec={v["s1"]}>{"Simulated workflow · No employer is contacted."}</StackText>{v["s2"]}{v["s3"]}</StackFragment>
    );
}
