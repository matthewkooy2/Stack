# Shared native view source, migrated from prototype/application-detail.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub application_detail_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="application-review" spec={v["s0"]}>
        <StackText kind="h3" variant="" spec={v["s1"]}>{"Save your notes?"}</StackText>
        <StackButton kind="button" variant="sheet-primary" spec={v["s2"]}>{"Save and close"}</StackButton>
        <StackButton kind="button" variant="application-secondary" spec={v["s3"]}>{"Discard notes"}</StackButton>
        <StackButton kind="button" variant="application-secondary" spec={v["s4"]}>{"Keep editing"}</StackButton></StackLayout>
    );
}

def:pub application_detail_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="application-error" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub application_detail_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="application-success" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub application_detail_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="jobs-loading-announcement" spec={v["s0"]}>{"Loading "}{v["s1"]}</StackLayout>
    );
}

def:pub application_detail_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="application-progress" spec={v["s0"]}>
        <StackText kind="strong" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackLayout kind="div" variant="application-placeholder" spec={v["s3"]}></StackLayout>
        <StackLayout kind="div" variant="application-placeholder short" spec={v["s4"]}></StackLayout></StackLayout>
    );
}

def:pub application_detail_10(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="small" variant="" spec={v["s0"]}>{v["s1"]}{" · "}{v["s2"]}</StackText>
    );
}

def:pub application_detail_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackLayout kind="span" variant="" spec={v["s1"]}>{v["s2"]}{v["s3"]}</StackLayout>
        <StackComponent kind="ChevronRight" variant="" spec={v["s4"]}></StackComponent></StackButton>
    );
}

def:pub application_detail_11(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub application_detail_12(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub application_detail_13(v: dict[str, any]) -> JsxElement {
    return (
    <StackOption kind="option" variant="" spec={v["s0"]}>{v["s1"]}</StackOption>
    );
}

def:pub application_detail_14(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="application-muted" spec={v["s0"]}>{v["s1"]}{" · "}{v["s2"]}</StackText>
    <StackButton kind="button" variant="application-secondary" spec={v["s3"]}>{"Preview attached resume"}</StackButton></StackFragment>
    );
}

def:pub application_detail_15(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="application-muted" spec={v["s0"]}>{"Choose from your Resume library or add a PDF."}</StackText>
    );
}

def:pub application_detail_16(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="ApplicationDocument" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub application_detail_17(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="application-secondary" spec={v["s0"]}>{"Discard edits"}</StackButton>
    );
}

def:pub application_detail_18(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{"No status changes recorded yet."}</StackText>
    );
}

def:pub application_detail_21(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub application_detail_20(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>
        <StackText kind="strong" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackLayout kind="span" variant="" spec={v["s3"]}>{v["s4"]}{" · "}{v["s5"]}</StackLayout>{v["s6"]}</StackText>
    );
}

def:pub application_detail_19(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="ol" variant="application-history" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub application_detail_22(v: dict[str, any]) -> JsxElement {
    return (
    <StackOption kind="option" variant="" spec={v["s0"]}>{v["s1"]}</StackOption>
    );
}

def:pub application_detail_24(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="application-review" spec={v["s0"]}>
        <StackText kind="p" variant="" spec={v["s1"]}>{"Have you submitted this application on the employer’s site? This updates tracking only."}</StackText>
        <StackButton kind="button" variant="sheet-primary" spec={v["s2"]}>{"I confirm I submitted it"}</StackButton>
        <StackButton kind="button" variant="application-secondary" spec={v["s3"]}>{"Not yet"}</StackButton></StackLayout>
    );
}

def:pub application_detail_23(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackButton kind="button" variant="application-secondary" spec={v["s0"]}>{"Mark as submitted"}</StackButton>{v["s1"]}</StackFragment>
    );
}

def:pub application_detail_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="div" variant="application-next" spec={v["s0"]}>
        <StackLayout kind="div" variant="" spec={v["s1"]}>
            <StackText kind="strong" variant="" spec={v["s2"]}>{v["s3"]}</StackText>
            <StackText kind="p" variant="" spec={v["s4"]}>{v["s5"]}</StackText></StackLayout></StackLayout>
    <StackLayout kind="div" variant="application-actions" spec={v["s6"]}>{v["s7"]}</StackLayout>
    <StackDisclosure kind="details" variant="" spec={v["s8"]}>
        <StackSummary kind="summary" variant="" spec={v["s9"]}>{"Job details"}</StackSummary>
        <StackText kind="p" variant="" spec={v["s10"]}>{v["s11"]}</StackText>
        <StackText kind="h4" variant="" spec={v["s12"]}>{"Responsibilities"}</StackText>
        <StackLayout kind="ul" variant="" spec={v["s13"]}>{v["s14"]}</StackLayout>
        <StackText kind="h4" variant="" spec={v["s15"]}>{"Requirements"}</StackText>
        <StackLayout kind="ul" variant="" spec={v["s16"]}>{v["s17"]}</StackLayout>
        <StackButton kind="a" variant="application-text-link" spec={v["s18"]}>{"Open employer listing "}
            <StackComponent kind="ArrowUpRight" variant="" spec={v["s19"]}></StackComponent></StackButton>
        <StackText kind="p" variant="application-muted" spec={v["s20"]}>{"Sample listing and employer URL · "}{v["s21"]}{". Preparation is simulated, including on active demos."}</StackText></StackDisclosure>
    <StackDisclosure kind="details" variant="application-editor" spec={v["s22"]}>
        <StackSummary kind="summary" variant="" spec={v["s23"]}>{"Resume & notes"}{v["s24"]}</StackSummary>
        <StackLayout kind="label" variant="" spec={v["s25"]}>{"Attached resume"}
            <StackSelect kind="select" variant="" spec={v["s26"]}>
                <StackOption kind="option" variant="" spec={v["s27"]}>{"No resume selected"}</StackOption>{v["s28"]}</StackSelect></StackLayout>{v["s29"]}{v["s30"]}
        <StackLayout kind="label" variant="" spec={v["s31"]}>{"Add a PDF"}
            <StackInput kind="input" variant="" spec={v["s32"]}></StackInput></StackLayout>
        <StackButton kind="button" variant="application-secondary" spec={v["s33"]}>{"Use sample resume"}</StackButton>
        <StackButton kind="button" variant="application-secondary" spec={v["s34"]}>{"Manage Resume library"}</StackButton>
        <StackLayout kind="label" variant="" spec={v["s35"]}>{"Notes"}
            <StackInput kind="textarea" variant="" spec={v["s36"]}></StackInput></StackLayout>
        <StackButton kind="button" variant="sheet-primary" spec={v["s37"]}>{"Save notes "}
            <StackComponent kind="Check" variant="" spec={v["s38"]}></StackComponent></StackButton>{v["s39"]}</StackDisclosure>
    <StackDisclosure kind="details" variant="" spec={v["s40"]}>
        <StackSummary kind="summary" variant="" spec={v["s41"]}>{"Status history"}</StackSummary>{v["s42"]}
        <StackText kind="p" variant="application-muted" spec={v["s43"]}>{"Update only after checking the employer’s confirmation."}</StackText>
        <StackLayout kind="label" variant="" spec={v["s44"]}>{"Confirmed stage"}
            <StackSelect kind="select" variant="" spec={v["s45"]}>{v["s46"]}</StackSelect></StackLayout></StackDisclosure>{v["s47"]}</StackFragment>
    );
}

def:pub application_detail_26(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="label" variant="" spec={v["s0"]}>{v["s1"]}
        <StackInput kind="textarea" variant="" spec={v["s2"]}></StackInput></StackLayout>
    );
}

def:pub application_detail_27(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="application-empty" spec={v["s0"]}>{"Add and confirm facts above, or choose a confirmed resume in application details."}</StackText>
    );
}

def:pub application_detail_28(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="sheet-primary" spec={v["s0"]}>{v["s1"]}</StackButton>
    );
}

def:pub application_detail_31(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="blockquote" variant="" spec={v["s0"]}>{"“"}{v["s1"]}{"”"}
        <StackText kind="cite" variant="" spec={v["s2"]}>{v["s3"]}</StackText></StackText>
    );
}

def:pub application_detail_32(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{"No supporting fact was found. Add a real example if you have one; this is not proof you lack the skill."}</StackText>
    );
}

def:pub application_detail_30(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="application-review" spec={v["s0"]}>
        <StackText kind="h4" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>
            <StackText kind="strong" variant="" spec={v["s4"]}>{v["s5"]}</StackText></StackText>
        <StackText kind="blockquote" variant="" spec={v["s6"]}>{"“"}{v["s7"]}{"”"}
            <StackText kind="cite" variant="" spec={v["s8"]}>{"Sample employer listing"}</StackText></StackText>{v["s9"]}</StackLayout>
    );
}

def:pub application_detail_33(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub application_detail_29(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="application-pill" spec={v["s0"]}>{"Sample listing · Evidence-based mock result"}</StackText>
    <StackText kind="p" variant="" spec={v["s1"]}>{v["s2"]}</StackText>{v["s3"]}
    <StackText kind="h4" variant="" spec={v["s4"]}>{"Unknowns to clarify"}</StackText>
    <StackLayout kind="ul" variant="" spec={v["s5"]}>{v["s6"]}</StackLayout>
    <StackText kind="h4" variant="" spec={v["s7"]}>{"Suggested next step"}</StackText>
    <StackText kind="p" variant="" spec={v["s8"]}>{"Bring a specific example for each unsupported requirement and confirm the unknowns with the employer."}</StackText>
    <StackButton kind="button" variant="application-secondary" spec={v["s9"]}>{"Prepare application"}</StackButton></StackFragment>
    );
}

def:pub application_detail_25(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="h3" variant="" spec={v["s0"]}>{"Evidence for this role"}</StackText>
    <StackText kind="p" variant="" spec={v["s1"]}>{"Compare the sample listing with facts you confirmed. A resume is optional."}</StackText>
    <StackDisclosure kind="details" variant="" spec={v["s2"]}>
        <StackSummary kind="summary" variant="" spec={v["s3"]}>{"Confirmed facts"}</StackSummary>{v["s4"]}
        <StackLayout kind="label" variant="application-checkbox" spec={v["s5"]}>
            <StackInput kind="input" variant="" spec={v["s6"]}></StackInput>{"I confirm these facts for this prototype."}</StackLayout>
        <StackButton kind="button" variant="application-secondary" spec={v["s7"]}>{"Save confirmed facts"}</StackButton></StackDisclosure>{v["s8"]}{v["s9"]}</StackFragment>
    );
}

def:pub application_detail_34(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="ApplicationTask" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub application_detail_36(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="application-empty" spec={v["s0"]}>{"No follow-ups yet."}</StackText>
    );
}

def:pub application_detail_38(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>{"Complete"}</StackButton>
    );
}

def:pub application_detail_37(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="application-reminder" spec={v["s0"]}>
        <StackText kind="strong" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{v["s4"]}{" · "}{v["s5"]}</StackText>
        <StackLayout kind="div" variant="" spec={v["s6"]}>{v["s7"]}
            <StackButton kind="button" variant="" spec={v["s8"]}>{"Reschedule"}</StackButton>
            <StackButton kind="button" variant="" spec={v["s9"]}>{"Delete"}</StackButton></StackLayout></StackLayout>
    );
}

def:pub application_detail_39(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="application-secondary" spec={v["s0"]}>{"Cancel edit"}</StackButton>
    );
}

def:pub application_detail_35(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="h3" variant="" spec={v["s0"]}>{"Your next steps"}</StackText>
    <StackText kind="p" variant="application-muted" spec={v["s1"]}>{"Local reminders · No emails or notifications are sent."}</StackText>{v["s2"]}{v["s3"]}
    <StackLayout kind="label" variant="" spec={v["s4"]}>{"Reminder"}
        <StackInput kind="input" variant="" spec={v["s5"]}></StackInput></StackLayout>
    <StackLayout kind="label" variant="" spec={v["s6"]}>{"Date and time"}
        <StackInput kind="input" variant="" spec={v["s7"]}></StackInput></StackLayout>
    <StackButton kind="button" variant="sheet-primary" spec={v["s8"]}>{v["s9"]}</StackButton>{v["s10"]}</StackFragment>
    );
}

def:pub application_detail_41(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="sheet-primary" spec={v["s0"]}>{"Build plan"}</StackButton>
    );
}

def:pub application_detail_43(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>
        <StackText kind="h4" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{v["s4"]}</StackText>
        <StackText kind="p" variant="" spec={v["s5"]}>{v["s6"]}{" min"}{v["s7"]}</StackText></StackText>
    );
}

def:pub application_detail_44(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="application-review" spec={v["s0"]}>{"Your note: "}{v["s1"]}</StackText>
    );
}

def:pub application_detail_42(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="ol" variant="application-plan" spec={v["s0"]}>{v["s1"]}</StackLayout>{v["s2"]}
    <StackButton kind="button" variant="sheet-primary" spec={v["s3"]}>{"Open job plan in Prep "}
        <StackComponent kind="ArrowUpRight" variant="" spec={v["s4"]}></StackComponent></StackButton>
    <StackButton kind="button" variant="application-secondary" spec={v["s5"]}>{"Refresh plan"}</StackButton>
    <StackText kind="p" variant="application-muted" spec={v["s6"]}>{"Existing practice notes and completed sessions are kept."}</StackText></StackFragment>
    );
}

def:pub application_detail_40(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="h3" variant="" spec={v["s0"]}>{"Practice for "}{v["s1"]}</StackText>
    <StackText kind="p" variant="" spec={v["s2"]}>{"Selected from this job’s responsibilities and requirements."}</StackText>{v["s3"]}</StackFragment>
    );
}

def:pub application_detail_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>{v["s0"]}{v["s1"]}{v["s2"]}{v["s3"]}{v["s4"]}</StackFragment>
    );
}

def:pub application_detail_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="application-focus-page" spec={v["s0"]}>
        <StackLayout kind="section" variant="jobs-sheet application-detail application-workflow" spec={v["s1"]}>
            <StackLayout kind="div" variant="application-flow-nav" spec={v["s2"]}>
                <StackButton kind="button" variant="" spec={v["s3"]}>
                    <StackComponent kind="ArrowLeft" variant="" spec={v["s4"]}></StackComponent></StackButton>
                <StackLayout kind="span" variant="" spec={v["s5"]}>{v["s6"]}</StackLayout>
                <StackLayout kind="span" variant="application-demo" spec={v["s7"]}>{"Prototype"}</StackLayout></StackLayout>
            <StackLayout kind="span" variant="sheet-eyebrow" spec={v["s8"]}>{v["s9"]}</StackLayout>
            <StackText kind="h2" variant="" spec={v["s10"]}>{v["s11"]}</StackText>
            <StackText kind="p" variant="" spec={v["s12"]}>{v["s13"]}{" · "}{v["s14"]}</StackText>{v["s15"]}{v["s16"]}{v["s17"]}{v["s18"]}
            <StackLayout kind="div" variant="" spec={v["s19"]}>{v["s20"]}</StackLayout></StackLayout></StackLayout>
    );
}
