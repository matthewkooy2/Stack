# Shared native view source, migrated from prototype/resume.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub resume_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="jobs-loading-announcement" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub resume_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackComponent kind="ArrowLeft" variant="" spec={v["s1"]}></StackComponent></StackButton>
    );
}

def:pub resume_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackComponent kind="Plus" variant="" spec={v["s1"]}></StackComponent></StackButton>
    );
}

def:pub resume_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-start" spec={v["s0"]}>
        <StackText kind="p" variant="resume-intro" spec={v["s1"]}>{"Start with what you have."}
            <StackLayout kind="br" variant="" spec={v["s2"]}></StackLayout>{"Or build something new."}</StackText>
        <StackLayout kind="div" variant="resume-choices" spec={v["s3"]}>
            <StackButton kind="button" variant="" spec={v["s4"]}>
                <StackComponent kind="Upload" variant="" spec={v["s5"]}></StackComponent>
                <StackLayout kind="span" variant="" spec={v["s6"]}>
                    <StackText kind="strong" variant="" spec={v["s7"]}>{"Upload resume"}</StackText>
                    <StackText kind="small" variant="" spec={v["s8"]}>{"Bring a PDF. Review your details."}</StackText></StackLayout>
                <StackComponent kind="ChevronRight" variant="" spec={v["s9"]}></StackComponent></StackButton>
            <StackButton kind="button" variant="" spec={v["s10"]}>
                <StackComponent kind="FileText" variant="" spec={v["s11"]}></StackComponent>
                <StackLayout kind="span" variant="" spec={v["s12"]}>
                    <StackText kind="strong" variant="" spec={v["s13"]}>{"Use template"}</StackText>
                    <StackText kind="small" variant="" spec={v["s14"]}>{"Choose a layout. Make it yours."}</StackText></StackLayout>
                <StackComponent kind="ChevronRight" variant="" spec={v["s15"]}></StackComponent></StackButton></StackLayout>
        <StackText kind="p" variant="resume-footnote" spec={v["s16"]}>{"Either way, you confirm every detail."}</StackText></StackLayout>
    );
}

def:pub resume_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>{v["s1"]}</StackButton>
    );
}

def:pub resume_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="resume-document" spec={v["s0"]}>
        <StackLayout kind="span" variant="resume-file-icon" spec={v["s1"]}>
            <StackComponent kind="FileText" variant="" spec={v["s2"]}></StackComponent></StackLayout>
        <StackLayout kind="span" variant="" spec={v["s3"]}>
            <StackText kind="strong" variant="" spec={v["s4"]}>{v["s5"]}</StackText>
            <StackText kind="small" variant="" spec={v["s6"]}>{v["s7"]}{v["s8"]}{" · "}{v["s9"]}</StackText></StackLayout>
        <StackComponent kind="ChevronRight" variant="" spec={v["s10"]}></StackComponent></StackButton>
    );
}

def:pub resume_10(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-empty" spec={v["s0"]}>
        <StackText kind="h2" variant="" spec={v["s1"]}>{"No original resumes"}</StackText>
        <StackText kind="p" variant="" spec={v["s2"]}>{"Add a resume to score or tailor for a job."}</StackText>
        <StackButton kind="button" variant="resume-secondary" spec={v["s3"]}>{"Add resume"}</StackButton></StackLayout>
    );
}

def:pub resume_11(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="resume-footnote" spec={v["s0"]}>{"Tailoring keeps your originals unchanged."}</StackText>
    );
}

def:pub resume_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>{v["s0"]}{v["s1"]}</StackFragment>
    );
}

def:pub resume_12(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="resume-document" spec={v["s0"]}>
        <StackLayout kind="span" variant="resume-file-icon" spec={v["s1"]}>
            <StackComponent kind="FileText" variant="" spec={v["s2"]}></StackComponent></StackLayout>
        <StackLayout kind="span" variant="" spec={v["s3"]}>
            <StackText kind="strong" variant="" spec={v["s4"]}>{v["s5"]}</StackText>
            <StackText kind="small" variant="" spec={v["s6"]}>{"Approved · "}{v["s7"]}</StackText></StackLayout>
        <StackComponent kind="ChevronRight" variant="" spec={v["s8"]}></StackComponent></StackButton>
    );
}

def:pub resume_14(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="" spec={v["s0"]}>
        <StackLayout kind="i" variant="" spec={v["s1"]}></StackLayout>
        <StackLayout kind="span" variant="" spec={v["s2"]}>
            <StackText kind="b" variant="" spec={v["s3"]}></StackText>
            <StackText kind="small" variant="" spec={v["s4"]}></StackText></StackLayout></StackLayout>
    );
}

def:pub resume_13(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-library-placeholder" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub resume_15(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-empty" spec={v["s0"]}>
        <StackComponent kind="Layers" variant="" spec={v["s1"]}></StackComponent>
        <StackText kind="h2" variant="" spec={v["s2"]}>{"A resume for each next step."}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{"Versions tailored to a job will appear here."}</StackText>
        <StackButton kind="button" variant="resume-text-link" spec={v["s4"]}>{"Explore jobs "}
            <StackComponent kind="ArrowUpRight" variant="" spec={v["s5"]}></StackComponent></StackButton></StackLayout>
    );
}

def:pub resume_16(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="resume-notice" spec={v["s0"]}>
        <StackComponent kind="Check" variant="" spec={v["s1"]}></StackComponent>{v["s2"]}</StackText>
    );
}

def:pub resume_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="div" variant="resume-tabs" spec={v["s0"]}>{v["s1"]}</StackLayout>{v["s2"]}{v["s3"]}</StackFragment>
    );
}

def:pub resume_17(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="resume-intro" spec={v["s0"]}>{"We’ll organize your experience."}
        <StackLayout kind="br" variant="" spec={v["s1"]}></StackLayout>{"You’ll review it before anything is saved."}</StackText>
    <StackButton kind="button" variant="resume-upload resume-upload-large" spec={v["s2"]}>
        <StackComponent kind="Upload" variant="" spec={v["s3"]}></StackComponent>
        <StackLayout kind="span" variant="" spec={v["s4"]}>{"Choose a PDF"}
            <StackText kind="small" variant="" spec={v["s5"]}>{"Up to 10 MB"}</StackText></StackLayout>
        <StackComponent kind="Plus" variant="" spec={v["s6"]}></StackComponent></StackButton>
    <StackInput kind="input" variant="" spec={v["s7"]}></StackInput>
    <StackButton kind="button" variant="resume-text-link resume-sample" spec={v["s8"]}>{"Try a sample resume "}
        <StackComponent kind="ArrowUpRight" variant="" spec={v["s9"]}></StackComponent></StackButton>
    <StackText kind="p" variant="resume-footnote" spec={v["s10"]}>{"Prototype: files stay in your browser. Parsing is simulated with sample details."}</StackText></StackFragment>
    );
}

def:pub resume_19(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub resume_20(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="label" variant="" spec={v["s0"]}>{v["s1"]}{v["s2"]}
        <StackLayout kind="span" variant="resume-input-placeholder" spec={v["s3"]}></StackLayout></StackLayout>
    );
}

def:pub resume_18(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="div" variant="resume-progress" spec={v["s0"]}>{v["s1"]}</StackLayout>
    <StackLayout kind="div" variant="resume-step-label" spec={v["s2"]}>{"1 of 4"}</StackLayout>
    <StackText kind="h2" variant="resume-field-title" spec={v["s3"]}>{"Personal details"}</StackText>
    <StackText kind="p" variant="resume-intro resume-field-intro" spec={v["s4"]}>{"Organizing your details for review."}</StackText>
    <StackLayout kind="div" variant="resume-section resume-wizard-fields" spec={v["s5"]}>{v["s6"]}</StackLayout>
    <StackButton kind="button" variant="resume-primary" spec={v["s7"]}>{"Continue "}
        <StackComponent kind="ChevronRight" variant="" spec={v["s8"]}></StackComponent></StackButton></StackFragment>
    );
}

def:pub resume_23(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Check" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub resume_22(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackLayout kind="div" variant="" spec={v["s1"]}>
            <StackText kind="b" variant="" spec={v["s2"]}>{"Your name"}</StackText>
            <StackLayout kind="span" variant="" spec={v["s3"]}></StackLayout>
            <StackLayout kind="i" variant="" spec={v["s4"]}></StackLayout>
            <StackLayout kind="i" variant="" spec={v["s5"]}></StackLayout>
            <StackText kind="em" variant="" spec={v["s6"]}>{"Experience"}</StackText>
            <StackLayout kind="i" variant="" spec={v["s7"]}></StackLayout>
            <StackLayout kind="i" variant="" spec={v["s8"]}></StackLayout>
            <StackText kind="em" variant="" spec={v["s9"]}>{"Education"}</StackText>
            <StackLayout kind="i" variant="" spec={v["s10"]}></StackLayout>
            <StackLayout kind="i" variant="" spec={v["s11"]}></StackLayout></StackLayout>
        <StackLayout kind="div" variant="" spec={v["s12"]}>
            <StackText kind="strong" variant="" spec={v["s13"]}>{v["s14"]}</StackText>
            <StackText kind="small" variant="" spec={v["s15"]}>{v["s16"]}</StackText>{v["s17"]}</StackLayout></StackButton>
    );
}

def:pub resume_21(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="resume-intro" spec={v["s0"]}>{"A simple starting point for your story."}</StackText>
    <StackLayout kind="div" variant="resume-templates" spec={v["s1"]}>{v["s2"]}</StackLayout>
    <StackButton kind="button" variant="resume-primary" spec={v["s3"]}>{"Use this template "}
        <StackComponent kind="ChevronRight" variant="" spec={v["s4"]}></StackComponent></StackButton>
    <StackText kind="p" variant="resume-footnote" spec={v["s5"]}>{"Next, add your details. No existing resume needed."}</StackText></StackFragment>
    );
}

def:pub resume_25(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub resume_27(v: dict[str, any]) -> JsxElement {
    return (
    <StackInput kind="input" variant="" spec={v["s0"]}></StackInput>
    );
}

def:pub resume_28(v: dict[str, any]) -> JsxElement {
    return (
    <StackInput kind="textarea" variant="" spec={v["s0"]}></StackInput>
    );
}

def:pub resume_26(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="label" variant="" spec={v["s0"]}>{v["s1"]}{v["s2"]}{v["s3"]}</StackLayout>
    );
}

def:pub resume_29(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="resume-footnote" spec={v["s0"]}>{"Simulated extraction · sample information"}</StackText>
    );
}

def:pub resume_24(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="div" variant="resume-progress" spec={v["s0"]}>{v["s1"]}</StackLayout>
    <StackLayout kind="div" variant="resume-step-label" spec={v["s2"]}>{v["s3"]}{" of 4"}</StackLayout>
    <StackText kind="h2" variant="resume-field-title" spec={v["s4"]}>{v["s5"]}</StackText>
    <StackText kind="p" variant="resume-intro resume-field-intro" spec={v["s6"]}>{v["s7"]}</StackText>
    <StackLayout kind="div" variant="resume-section resume-wizard-fields" spec={v["s8"]}>{v["s9"]}</StackLayout>
    <StackButton kind="button" variant="resume-primary" spec={v["s10"]}>{v["s11"]}{" "}
        <StackComponent kind="ChevronRight" variant="" spec={v["s12"]}></StackComponent></StackButton>{v["s13"]}</StackFragment>
    );
}

def:pub resume_32(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub resume_31(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-confirm-section" spec={v["s0"]}>
        <StackLayout kind="div" variant="" spec={v["s1"]}>
            <StackText kind="h2" variant="" spec={v["s2"]}>{v["s3"]}</StackText>
            <StackButton kind="button" variant="" spec={v["s4"]}>{"Edit"}</StackButton></StackLayout>{v["s5"]}</StackLayout>
    );
}

def:pub resume_30(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="resume-intro" spec={v["s0"]}>{"One last look before adding it to your resumes."}</StackText>{v["s1"]}
    <StackButton kind="button" variant="resume-primary" spec={v["s2"]}>{"Confirm resume "}
        <StackComponent kind="Check" variant="" spec={v["s3"]}></StackComponent></StackButton></StackFragment>
    );
}

def:pub resume_33(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="ResumeTools" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub resume_34(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="resume-error" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub resume_36(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub resume_35(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackComponent kind="Icon" variant="" spec={v["s1"]}></StackComponent>
        <StackLayout kind="span" variant="" spec={v["s2"]}>{v["s3"]}</StackLayout>{v["s4"]}</StackButton>
    );
}

def:pub resume_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="" spec={v["s0"]}>
        <StackComponent kind="ResumeScenarios" variant="" spec={v["s1"]}></StackComponent>
        <StackLayout kind="header" variant="jobs-header" spec={v["s2"]}>
            <StackButton kind="button" variant="" spec={v["s3"]}>
                <StackComponent kind="Menu" variant="" spec={v["s4"]}></StackComponent></StackButton>
            <StackLayout kind="span" variant="jobs-wordmark" spec={v["s5"]}>{"stack"}
                <StackLayout kind="span" variant="" spec={v["s6"]}>{"."}</StackLayout></StackLayout>
            <StackLayout kind="span" variant="" spec={v["s7"]}></StackLayout></StackLayout>
        <StackScroll kind="main" variant="resume-scroll" spec={v["s8"]}>{v["s9"]}
            <StackLayout kind="div" variant="resume-heading" spec={v["s10"]}>{v["s11"]}
                <StackText kind="h1" variant="" spec={v["s12"]}>{v["s13"]}</StackText>{v["s14"]}</StackLayout>{v["s15"]}{v["s16"]}</StackScroll>
        <StackLayout kind="nav" variant="jobs-nav" spec={v["s17"]}>{v["s18"]}</StackLayout></StackLayout>
    );
}
