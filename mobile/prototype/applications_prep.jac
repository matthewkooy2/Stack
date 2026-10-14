# Shared native view source, migrated from prototype/applications-prep.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub applications_prep_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="GeneralPrep" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub applications_prep_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="application-error" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub applications_prep_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{"Loading practice sessions…"}</StackText>
    );
}

def:pub applications_prep_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="" spec={v["s0"]}>{"No sessions were found for this application."}</StackText>
    <StackButton kind="button" variant="sheet-primary" spec={v["s1"]}>{"Build a plan in Applications"}</StackButton></StackFragment>
    );
}

def:pub applications_prep_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="h3" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    <StackText kind="p" variant="" spec={v["s2"]}>{v["s3"]}</StackText>
    <StackText kind="p" variant="application-muted" spec={v["s4"]}>{v["s5"]}{v["s6"]}{" min · Self-guided practice"}</StackText>
    <StackLayout kind="label" variant="" spec={v["s7"]}>{"Your practice notes"}
        <StackInput kind="textarea" variant="" spec={v["s8"]}></StackInput></StackLayout>
    <StackLayout kind="label" variant="" spec={v["s9"]}>{"Focus for next practice"}
        <StackSelect kind="select" variant="" spec={v["s10"]}>
            <StackOption kind="option" variant="" spec={v["s11"]}>{"No additional focus"}</StackOption>
            <StackOption kind="option" variant="" spec={v["s12"]}>{"Reflection"}</StackOption>
            <StackOption kind="option" variant="" spec={v["s13"]}>{"Edge cases"}</StackOption></StackSelect></StackLayout>
    <StackButton kind="button" variant="sheet-primary" spec={v["s14"]}>{"Save notes"}</StackButton>
    <StackButton kind="button" variant="application-secondary" spec={v["s15"]}>{"Complete practice "}
        <StackComponent kind="Check" variant="" spec={v["s16"]}></StackComponent></StackButton></StackFragment>
    );
}

def:pub applications_prep_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Check" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub applications_prep_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackLayout kind="span" variant="" spec={v["s1"]}>
            <StackText kind="strong" variant="" spec={v["s2"]}>{v["s3"]}</StackText>
            <StackText kind="small" variant="" spec={v["s4"]}>{v["s5"]}{" min · "}{v["s6"]}</StackText></StackLayout>{v["s7"]}</StackButton>
    );
}

def:pub applications_prep_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="application-actions" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub applications_prep_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="jobs-preview applications-preview" spec={v["s0"]}>
        <StackScroll kind="main" variant="jobs-sheet application-workflow application-prep-focus" spec={v["s1"]}>
            <StackLayout kind="div" variant="application-flow-nav" spec={v["s2"]}>
                <StackButton kind="button" variant="" spec={v["s3"]}>
                    <StackComponent kind="ArrowLeft" variant="" spec={v["s4"]}></StackComponent></StackButton>
                <StackLayout kind="span" variant="" spec={v["s5"]}>{v["s6"]}</StackLayout>
                <StackLayout kind="span" variant="application-demo" spec={v["s7"]}>{"Prototype"}</StackLayout></StackLayout>
            <StackText kind="h2" variant="" spec={v["s8"]}>{v["s9"]}</StackText>
            <StackText kind="p" variant="" spec={v["s10"]}>{v["s11"]}</StackText>{v["s12"]}{v["s13"]}
            <StackLayout kind="div" variant="" spec={v["s14"]}>{v["s15"]}
                <StackButton kind="button" variant="application-secondary" spec={v["s16"]}>{"Browse all Prep practice"}</StackButton></StackLayout></StackScroll></StackLayout>
    );
}
