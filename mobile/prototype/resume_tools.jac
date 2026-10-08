# Shared native view source, migrated from prototype/resume-tools.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub resume_tools_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{v["s1"]}{": "}{v["s2"]}{" of "}{v["s3"]}</StackText>
    );
}

def:pub resume_tools_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub resume_tools_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-score" spec={v["s0"]}>
        <StackText kind="h2" variant="" spec={v["s1"]}>{"Score for this job"}</StackText>
        <StackText kind="p" variant="" spec={v["s2"]}>
            <StackText kind="strong" variant="" spec={v["s3"]}>{"Job match: "}{v["s4"]}{v["s5"]}{"/100"}</StackText></StackText>
        <StackText kind="p" variant="" spec={v["s6"]}>
            <StackText kind="strong" variant="" spec={v["s7"]}>{"Resume quality: "}{v["s8"]}{v["s9"]}{"/100"}</StackText></StackText>
        <StackDisclosure kind="details" variant="" spec={v["s10"]}>
            <StackSummary kind="summary" variant="" spec={v["s11"]}>{"Score details"}</StackSummary>{v["s12"]}
            <StackText kind="p" variant="" spec={v["s13"]}>{v["s14"]}</StackText>{v["s15"]}
            <StackText kind="p" variant="" spec={v["s16"]}>{"Add missing skills only if true. These simplified prototype scores are not hiring predictions; production uses additional evidence and quality criteria."}</StackText></StackDisclosure></StackLayout>
    );
}

def:pub resume_tools_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>{v["s1"]}
        <StackLayout kind="span" variant="" spec={v["s2"]}>{"›"}</StackLayout></StackButton>
    );
}

def:pub resume_tools_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>{"Review details "}
        <StackLayout kind="span" variant="" spec={v["s1"]}>{"›"}</StackLayout></StackButton>
    );
}

def:pub resume_tools_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="" spec={v["s0"]}>
        <StackText kind="h3" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{v["s4"]}</StackText></StackLayout>
    );
}

def:pub resume_tools_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="resume-intro" spec={v["s0"]}>{v["s1"]}</StackText>
    <StackLayout kind="div" variant="resume-tool-menu" spec={v["s2"]}>{v["s3"]}{v["s4"]}</StackLayout>
    <StackDisclosure kind="details" variant="resume-content-preview" spec={v["s5"]}>
        <StackSummary kind="summary" variant="" spec={v["s6"]}>{"Confirmed details"}</StackSummary>
        <StackLayout kind="article" variant="" spec={v["s7"]}>
            <StackText kind="h2" variant="" spec={v["s8"]}>{v["s9"]}</StackText>
            <StackText kind="p" variant="" spec={v["s10"]}>{v["s11"]}</StackText>{v["s12"]}</StackLayout></StackDisclosure></StackFragment>
    );
}

def:pub resume_tools_10(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{"Loading resume tools…"}</StackText>
    );
}

def:pub resume_tools_12(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="resume-secondary" spec={v["s0"]}>{v["s1"]}</StackButton>
    );
}

def:pub resume_tools_13(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="" spec={v["s0"]}>
        <StackText kind="p" variant="" spec={v["s1"]}>{"Delete “"}{v["s2"]}{"”? This cannot be undone. Other versions stay in your library."}{v["s3"]}</StackText>
        <StackButton kind="button" variant="resume-danger" spec={v["s4"]}>{"Delete permanently"}</StackButton>
        <StackButton kind="button" variant="resume-secondary" spec={v["s5"]}>{"Keep resume"}</StackButton></StackLayout>
    );
}

def:pub resume_tools_11(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="label" variant="" spec={v["s0"]}>{"Resume name"}
        <StackInput kind="input" variant="" spec={v["s1"]}></StackInput></StackLayout>
    <StackButton kind="button" variant="resume-primary" spec={v["s2"]}>{"Save name"}</StackButton>{v["s3"]}
    <StackButton kind="button" variant="resume-text-link" spec={v["s4"]}>{"Delete resume"}</StackButton>{v["s5"]}</StackFragment>
    );
}

def:pub resume_tools_15(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{v["message"]}</StackText>
    );
}

def:pub resume_tools_16(v: dict[str, any]) -> JsxElement {
    return (
    <StackOption kind="option" variant="" spec={v["s0"]}>{v["s1"]}{" · "}{v["s2"]}</StackOption>
    );
}

def:pub resume_tools_17(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{"No saved jobs yet. Save one from Jobs, then return here."}</StackText>
    );
}

def:pub resume_tools_18(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Score" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub resume_tools_20(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="resume-secondary" spec={v["s0"]}>{"Review changes"}</StackButton>
    );
}

def:pub resume_tools_21(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="resume-secondary" spec={v["s0"]}>{"Set up format"}</StackButton>
    );
}

def:pub resume_tools_22(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="resume-secondary" spec={v["s0"]}>{"Open tailored resume"}</StackButton>
    );
}

def:pub resume_tools_23(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="resume-secondary" spec={v["s0"]}>{"Retry tailoring"}</StackButton>
    );
}

def:pub resume_tools_19(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-task" spec={v["s0"]}>
        <StackText kind="h2" variant="" spec={v["s1"]}>{"Latest tailoring task"}</StackText>
        <StackText kind="p" variant="" spec={v["s2"]}>{v["s3"]}{" · "}{v["s4"]}</StackText>
        <StackText kind="p" variant="" spec={v["s5"]}>{v["s6"]}</StackText>{v["s7"]}{v["s8"]}{v["s9"]}{v["s10"]}</StackLayout>
    );
}

def:pub resume_tools_14(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="" spec={v["s0"]}>{"Choose a saved job to score or tailor this resume."}</StackText>{v["s1"]}
    <StackLayout kind="label" variant="" spec={v["s2"]}>{"Saved job"}
        <StackSelect kind="select" variant="" spec={v["s3"]}>
            <StackOption kind="option" variant="" spec={v["s4"]}>{"Choose a saved job"}</StackOption>{v["s5"]}</StackSelect></StackLayout>{v["s6"]}
    <StackButton kind="button" variant="resume-secondary" spec={v["s7"]}>{"Score my resume"}</StackButton>{v["s8"]}
    <StackButton kind="button" variant="resume-primary" spec={v["s9"]}>{"Start tailoring"}</StackButton>
    <StackButton kind="button" variant="resume-secondary" spec={v["s10"]}>{"Headline & about suggestions"}</StackButton>{v["s11"]}
    <StackText kind="p" variant="resume-footnote" spec={v["s12"]}>{"Saved jobs and agent work are simulated in this preview."}</StackText></StackFragment>
    );
}

def:pub resume_tools_25(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{"No wording or order changes are needed. You can save a job-specific version with the original details."}</StackText>
    );
}

def:pub resume_tools_26(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-change" spec={v["s0"]}>
        <StackText kind="h2" variant="" spec={v["s1"]}>{v["s2"]}{" · "}{v["s3"]}</StackText>
        <StackText kind="p" variant="" spec={v["s4"]}>{v["s5"]}</StackText>
        <StackDisclosure kind="details" variant="" spec={v["s6"]}>
            <StackSummary kind="summary" variant="" spec={v["s7"]}>{"Compare text"}</StackSummary>
            <StackText kind="h3" variant="" spec={v["s8"]}>{"Original"}</StackText>
            <StackText kind="p" variant="resume-preserve" spec={v["s9"]}>{v["s10"]}</StackText>
            <StackText kind="h3" variant="" spec={v["s11"]}>{"Proposed"}</StackText>
            <StackText kind="p" variant="resume-preserve" spec={v["s12"]}>{v["s13"]}</StackText></StackDisclosure>
        <StackLayout kind="label" variant="resume-checkbox" spec={v["s14"]}>
            <StackInput kind="input" variant="" spec={v["s15"]}></StackInput>{"Keep this change"}</StackLayout></StackLayout>
    );
}

def:pub resume_tools_24(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="" spec={v["s0"]}>{v["s1"]}{" · "}{v["s2"]}</StackText>
    <StackComponent kind="Score" variant="" spec={v["s3"]}></StackComponent>
    <StackText kind="p" variant="" spec={v["s4"]}>{v["s5"]}{" of "}{v["s6"]}{" changes kept"}</StackText>{v["s7"]}{v["s8"]}
    <StackDisclosure kind="details" variant="" spec={v["s9"]}>
        <StackSummary kind="summary" variant="" spec={v["s10"]}>{"Removed content"}</StackSummary>
        <StackText kind="p" variant="" spec={v["s11"]}>{v["s12"]}</StackText></StackDisclosure>
    <StackDisclosure kind="details" variant="" spec={v["s13"]}>
        <StackSummary kind="summary" variant="" spec={v["s14"]}>{"Original text"}</StackSummary>
        <StackText kind="p" variant="resume-preserve" spec={v["s15"]}>{v["s16"]}</StackText></StackDisclosure>
    <StackDisclosure kind="details" variant="" spec={v["s17"]}>
        <StackSummary kind="summary" variant="" spec={v["s18"]}>{"Tailored text"}</StackSummary>
        <StackText kind="p" variant="resume-preserve" spec={v["s19"]}>{v["s20"]}</StackText></StackDisclosure>
    <StackButton kind="button" variant="resume-secondary" spec={v["s21"]}>{"Preview proposed PDF"}</StackButton>
    <StackText kind="p" variant="resume-footnote" spec={v["s22"]}>{"Preview reflects the changes currently kept. Uploaded LaTeX layout compilation is simulated; this PDF uses the preview layout."}</StackText>
    <StackButton kind="button" variant="resume-primary" spec={v["s23"]}>{"Approve kept changes & save"}</StackButton></StackFragment>
    );
}

def:pub resume_tools_27(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="h2" variant="" spec={v["s0"]}>{"Your tailored resume is ready."}</StackText>
    <StackText kind="p" variant="" spec={v["s1"]}>{"The original is unchanged. Your approved version and parser results are in Tailored."}</StackText>
    <StackButton kind="button" variant="resume-primary" spec={v["s2"]}>{"Open tailored resume"}</StackButton></StackFragment>
    );
}

def:pub resume_tools_29(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="label" variant="" spec={v["s0"]}>{"Suggested headline"}
        <StackInput kind="input" variant="" spec={v["s1"]}></StackInput></StackLayout>
    <StackLayout kind="label" variant="" spec={v["s2"]}>{"Suggested about"}
        <StackInput kind="textarea" variant="" spec={v["s3"]}></StackInput></StackLayout>
    <StackButton kind="button" variant="resume-primary" spec={v["s4"]}>{v["s5"]}</StackButton>
    <StackText kind="p" variant="" spec={v["s6"]}>{"Your public profile stays unchanged. You can copy these suggestions when editing it."}</StackText></StackFragment>
    );
}

def:pub resume_tools_30(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{v["message"]}</StackText>
    );
}

def:pub resume_tools_28(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="" spec={v["s0"]}>{"Suggestions based on your confirmed resume details."}</StackText>
    <StackButton kind="button" variant="resume-secondary" spec={v["s1"]}>{v["s2"]}</StackButton>{v["s3"]}{v["s4"]}</StackFragment>
    );
}

def:pub resume_tools_32(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub resume_tools_34(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="resume-secondary" spec={v["s0"]}>{"Retry compilation"}</StackButton>
    );
}

def:pub resume_tools_35(v: dict[str, any]) -> JsxElement {
    return (
    <StackDisclosure kind="details" variant="" spec={v["s0"]}>
        <StackSummary kind="summary" variant="" spec={v["s1"]}>{"Other archive files"}</StackSummary>
        <StackText kind="p" variant="" spec={v["s2"]}>{v["s3"]}</StackText>
        <StackText kind="p" variant="" spec={v["s4"]}>{"This prototype inspects the main document only; production preserves supported project files."}</StackText></StackDisclosure>
    );
}

def:pub resume_tools_33(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackButton kind="button" variant="resume-text-link" spec={v["s0"]}>{"Remove format"}</StackButton>{v["s1"]}{v["s2"]}
    <StackButton kind="button" variant="resume-secondary" spec={v["s3"]}>{"Preview format"}</StackButton></StackFragment>
    );
}

def:pub resume_tools_36(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="resume-primary" spec={v["s0"]}>{"Continue to tailoring"}</StackButton>
    );
}

def:pub resume_tools_31(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="" spec={v["s0"]}>{"Keep your LaTeX source, or choose a built-in layout."}</StackText>
    <StackText kind="h2" variant="" spec={v["s1"]}>{v["s2"]}</StackText>{v["s3"]}
    <StackInput kind="input" variant="" spec={v["s4"]}></StackInput>
    <StackButton kind="button" variant="resume-secondary" spec={v["s5"]}>{v["s6"]}</StackButton>
    <StackText kind="p" variant="" spec={v["s7"]}>{"In Overleaf, download your project’s source, then upload it here."}</StackText>
    <StackLayout kind="label" variant="" spec={v["s8"]}>{"Built-in template"}
        <StackSelect kind="select" variant="" spec={v["s9"]}>
            <StackOption kind="option" variant="" spec={v["s10"]}>{"Choose a template"}</StackOption>
            <StackOption kind="option" variant="" spec={v["s11"]}>{"Jake’s Resume"}</StackOption>
            <StackOption kind="option" variant="" spec={v["s12"]}>{"Classic"}</StackOption></StackSelect></StackLayout>{v["s13"]}{v["s14"]}</StackFragment>
    );
}

def:pub resume_tools_39(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Score" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub resume_tools_38(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="" spec={v["s0"]}>{v["s1"]}{" · "}{v["s2"]}</StackText>
    <StackText kind="p" variant="" spec={v["s3"]}>{v["s4"]}{" · "}{v["s5"]}{" pages · From "}{v["s6"]}</StackText>{v["s7"]}
    <StackButton kind="button" variant="resume-secondary" spec={v["s8"]}>{"Preview PDF"}</StackButton>
    <StackButton kind="button" variant="resume-primary" spec={v["s9"]}>{"Download PDF"}</StackButton></StackFragment>
    );
}

def:pub resume_tools_40(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackDisclosure kind="details" variant="" spec={v["s0"]}>
        <StackSummary kind="summary" variant="" spec={v["s1"]}>{"View LaTeX source"}</StackSummary>
        <StackText kind="pre" variant="resume-code" spec={v["s2"]}>{v["s3"]}</StackText></StackDisclosure>
    <StackButton kind="button" variant="resume-secondary" spec={v["s4"]}>{"Download .tex source"}</StackButton>
    <StackButton kind="a" variant="resume-text-link" spec={v["s5"]}>{"Open Overleaf ↗"}</StackButton>
    <StackText kind="p" variant="resume-footnote" spec={v["s6"]}>{"PDFs use a paginated preview layout. LaTeX compilation is simulated; uploaded layout compilation is simulated. Approved text edits are applied to matching source content; unsupported mappings are blocked."}</StackText></StackFragment>
    );
}

def:pub resume_tools_43(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{v["s1"]}{" "}{v["s2"]}{": "}{v["s3"]}{v["s4"]}</StackText>
    );
}

def:pub resume_tools_42(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-checks" spec={v["s0"]}>
        <StackText kind="h2" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{v["s4"]}{" of "}{v["s5"]}{" checks passed"}</StackText>
        <StackDisclosure kind="details" variant="" spec={v["s6"]}>
            <StackSummary kind="summary" variant="" spec={v["s7"]}>{"Parser details"}</StackSummary>{v["s8"]}</StackDisclosure>
        <StackText kind="p" variant="resume-footnote" spec={v["s9"]}>{"Compares text extracted from every PDF page with each confirmed field and line. This preview uses PDF.js; production parsing follows its separately configured parser. Layout, reading order, and ATS compatibility are not guaranteed."}</StackText></StackLayout>
    );
}

def:pub resume_tools_41(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackButton kind="button" variant="resume-secondary" spec={v["s0"]}>{v["s1"]}</StackButton>{v["s2"]}</StackFragment>
    );
}

def:pub resume_tools_37(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>{v["s0"]}{v["s1"]}{v["s2"]}</StackFragment>
    );
}

def:pub resume_tools_44(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="resume-pdf-preview" spec={v["s0"]}>
        <StackButton kind="button" variant="resume-secondary" spec={v["s1"]}>{"Close preview"}</StackButton>
        <StackText kind="p" variant="" spec={v["s2"]}>{v["s3"]}{" "}{v["s4"]}</StackText>
        <StackComponent kind="PdfPreview" variant="" spec={v["s5"]}></StackComponent></StackLayout>
    );
}

def:pub resume_tools_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>{v["s0"]}
    <StackLayout kind="fieldset" variant="resume-tool-panel" spec={v["s1"]}>{v["s2"]}{v["s3"]}{v["s4"]}{v["s5"]}{v["s6"]}{v["s7"]}{v["s8"]}</StackLayout>{v["s9"]}</StackFragment>
    );
}

def:pub resume_tools_45(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-operation" spec={v["s0"]}>
        <StackText kind="p" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackButton kind="button" variant="resume-secondary" spec={v["s3"]}>{"Cancel"}</StackButton></StackLayout>
    );
}

def:pub resume_tools_46(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="resume-error" spec={v["s0"]}>
        <StackText kind="p" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackButton kind="button" variant="resume-secondary" spec={v["s3"]}>{"Retry"}</StackButton></StackLayout>
    );
}

def:pub resume_tools_47(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="resume-notice" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub resume_tools_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="" spec={v["s0"]}>{v["s1"]}{v["s2"]}{v["s3"]}{v["s4"]}</StackLayout>
    );
}
