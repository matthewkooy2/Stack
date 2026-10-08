# Shared native view source, migrated from prototype/prep.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub prep_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="jobs-preview prep-preview" spec={v["s0"]}>
        <StackComponent kind="MockInterview" variant="" spec={v["s1"]}></StackComponent></StackLayout>
    );
}

def:pub prep_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="jobs-loading-announcement" spec={v["s0"]}>{"Loading practice options"}</StackLayout>
    );
}

def:pub prep_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="calendar-heading" spec={v["s0"]}>
        <StackButton kind="button" variant="" spec={v["s1"]}>
            <StackComponent kind="ArrowLeft" variant="" spec={v["s2"]}></StackComponent></StackButton>
        <StackText kind="h1" variant="" spec={v["s3"]}>{v["s4"]}</StackText></StackLayout>
    );
}

def:pub prep_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="applications-intro" spec={v["s0"]}>
        <StackText kind="h1" variant="" spec={v["s1"]}>{"Prep"}</StackText></StackLayout>
    );
}

def:pub prep_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="prep-track" spec={v["s0"]}>
        <StackLayout kind="span" variant="" spec={v["s1"]}>
            <StackComponent kind="Icon" variant="" spec={v["s2"]}></StackComponent></StackLayout>
        <StackLayout kind="span" variant="" spec={v["s3"]}>
            <StackText kind="strong" variant="" spec={v["s4"]}>{v["s5"]}</StackText>
            <StackText kind="small" variant="" spec={v["s6"]}>{v["s7"]}</StackText></StackLayout>
        <StackComponent kind="ChevronRight" variant="" spec={v["s8"]}></StackComponent></StackButton>
    );
}

def:pub prep_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="prep-intro" spec={v["s0"]}>{"What would you like to practice?"}</StackText>{v["s1"]}</StackFragment>
    );
}

def:pub prep_10(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Check" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub prep_11(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="ChevronRight" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub prep_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="prep-question-row" spec={v["s0"]}>
        <StackLayout kind="span" variant="" spec={v["s1"]}>
            <StackText kind="strong" variant="" spec={v["s2"]}>{v["s3"]}</StackText>
            <StackText kind="small" variant="" spec={v["s4"]}>{v["s5"]}{" · "}{v["s6"]}</StackText></StackLayout>{v["s7"]}</StackButton>
    );
}

def:pub prep_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="prep-question-list" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub prep_12(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="MockInterview" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub prep_15(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub prep_14(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="prep-guide" spec={v["s0"]}>
        <StackLayout kind="ol" variant="" spec={v["s1"]}>{v["s2"]}</StackLayout>
        <StackText kind="p" variant="" spec={v["s3"]}>{v["s4"]}</StackText>
        <StackText kind="strong" variant="" spec={v["s5"]}>{"Check your answer"}</StackText>
        <StackText kind="p" variant="" spec={v["s6"]}>{v["s7"]}</StackText></StackLayout>
    );
}

def:pub prep_13(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="article" variant="prep-exercise" spec={v["s0"]}>
        <StackLayout kind="span" variant="prep-question-meta" spec={v["s1"]}>{v["s2"]}{" · "}{v["s3"]}</StackLayout>
        <StackText kind="h2" variant="" spec={v["s4"]}>{v["s5"]}</StackText>
        <StackText kind="p" variant="prep-prompt" spec={v["s6"]}>{v["s7"]}</StackText>
        <StackLayout kind="label" variant="prep-notes-label" spec={v["s8"]}>{"Your notes"}
            <StackInput kind="textarea" variant="" spec={v["s9"]}></StackInput></StackLayout>
        <StackButton kind="button" variant="prep-guide-toggle" spec={v["s10"]}>
            <StackLayout kind="span" variant="" spec={v["s11"]}>{"Practice guide"}</StackLayout>
            <StackComponent kind="ChevronDown" variant="" spec={v["s12"]}></StackComponent></StackButton>{v["s13"]}
        <StackButton kind="button" variant="sheet-primary prep-finish" spec={v["s14"]}>{"Finish practice "}
            <StackComponent kind="Check" variant="" spec={v["s15"]}></StackComponent></StackButton>
        <StackText kind="p" variant="prep-self-guided" spec={v["s16"]}>{"Self-guided · No score"}</StackText></StackLayout>
    );
}

def:pub prep_17(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub prep_16(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackComponent kind="Icon" variant="" spec={v["s1"]}></StackComponent>
        <StackLayout kind="span" variant="" spec={v["s2"]}>{v["s3"]}</StackLayout>{v["s4"]}</StackButton>
    );
}

def:pub prep_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="" spec={v["s0"]}>
        <StackLayout kind="header" variant="jobs-header" spec={v["s1"]}>
            <StackButton kind="button" variant="" spec={v["s2"]}>
                <StackComponent kind="Menu" variant="" spec={v["s3"]}></StackComponent></StackButton>
            <StackLayout kind="span" variant="jobs-wordmark" spec={v["s4"]}>{"stack"}
                <StackLayout kind="span" variant="" spec={v["s5"]}>{"."}</StackLayout></StackLayout>
            <StackLayout kind="span" variant="" spec={v["s6"]}></StackLayout></StackLayout>
        <StackScroll kind="main" variant="applications-scroll prep-scroll" spec={v["s7"]}>{v["s8"]}{v["s9"]}{v["s10"]}</StackScroll>
        <StackLayout kind="nav" variant="jobs-nav" spec={v["s11"]}>{v["s12"]}</StackLayout></StackLayout>
    );
}
