# Shared native view source, migrated from prototype/jobs.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub jobs_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub jobs_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="jobs-loading-announcement" spec={v["s0"]}>{"Loading opportunities"}</StackLayout>
    );
}

def:pub jobs_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub jobs_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Check" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub jobs_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="fact-dot" spec={v["s0"]}></StackLayout>
    );
}

def:pub jobs_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>{"Pass "}
    <StackLayout kind="span" variant="" spec={v["s0"]}>{"← · →"}</StackLayout>{" Save"}</StackFragment>
    );
}

def:pub jobs_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="article" variant="" spec={v["s0"]}>
        <StackLayout kind="div" variant="job-company-row" spec={v["s1"]}>
            <StackLayout kind="div" variant="job-company-icon" spec={v["s2"]}>{v["s3"]}</StackLayout>
            <StackLayout kind="div" variant="" spec={v["s4"]}>
                <StackText kind="strong" variant="" spec={v["s5"]}>{v["s6"]}</StackText>
                <StackLayout kind="span" variant="" spec={v["s7"]}>{v["posted"]}</StackLayout></StackLayout>
            <StackLayout kind="span" variant="opportunity-level" spec={v["s8"]}>{v["s9"]}</StackLayout></StackLayout>
        <StackLayout kind="div" variant="opportunity-body decision-body" spec={v["s10"]}>
            <StackText kind="h1" variant="" spec={v["s11"]}>{v["s12"]}</StackText>
            <StackLayout kind="div" variant="decision-pay" spec={v["s13"]}>
                <StackText kind="strong" variant="" spec={v["s14"]}>{v["s15"]}</StackText>
                <StackLayout kind="span" variant="" spec={v["s16"]}>{v["s17"]}{" · "}{v["s18"]}</StackLayout></StackLayout>
            <StackLayout kind="div" variant="decision-facts" spec={v["s19"]}>
                <StackLayout kind="div" variant="" spec={v["s20"]}>
                    <StackComponent kind="MapPin" variant="" spec={v["s21"]}></StackComponent>
                    <StackLayout kind="span" variant="" spec={v["s22"]}>{v["s23"]}
                        <StackText kind="small" variant="" spec={v["s24"]}>{v["s25"]}</StackText></StackLayout></StackLayout>
                <StackLayout kind="div" variant="" spec={v["s26"]}>
                    <StackComponent kind="BriefcaseBusiness" variant="" spec={v["s27"]}></StackComponent>
                    <StackLayout kind="span" variant="" spec={v["s28"]}>{v["s29"]}
                        <StackText kind="small" variant="" spec={v["s30"]}>{v["s31"]}</StackText></StackLayout></StackLayout></StackLayout>
            <StackLayout kind="section" variant="decision-section" spec={v["s32"]}>
                <StackText kind="h2" variant="" spec={v["s33"]}>{"THE WORK"}</StackText>
                <StackLayout kind="ul" variant="" spec={v["s34"]}>{v["s35"]}</StackLayout></StackLayout>
            <StackLayout kind="section" variant="decision-section" spec={v["s36"]}>
                <StackText kind="h2" variant="" spec={v["s37"]}>{"WHAT YOU NEED"}</StackText>
                <StackText kind="p" variant="" spec={v["s38"]}>{v["s39"]}</StackText>
                <StackText kind="p" variant="decision-skills" spec={v["s40"]}>{v["s41"]}</StackText></StackLayout>
            <StackLayout kind="div" variant="" spec={v["s42"]}>{v["s43"]}{v["s44"]}</StackLayout>
            <StackButton kind="button" variant="job-details-link" spec={v["s45"]}>{"Full job details "}
                <StackComponent kind="ArrowUpRight" variant="" spec={v["s46"]}></StackComponent></StackButton></StackLayout>
        <StackLayout kind="div" variant="job-card-actions" spec={v["s47"]}>
            <StackButton kind="button" variant="job-pass" spec={v["s48"]}>
                <StackComponent kind="X" variant="" spec={v["s49"]}></StackComponent></StackButton>
            <StackLayout kind="span" variant="swipe-guidance" spec={v["s50"]}>{v["s51"]}</StackLayout>
            <StackButton kind="button" variant="job-save" spec={v["s52"]}>
                <StackComponent kind="Bookmark" variant="" spec={v["s53"]}></StackComponent></StackButton></StackLayout></StackLayout>
    );
}

def:pub jobs_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="jobs-finished" spec={v["s0"]}>
        <StackComponent kind="Layers" variant="" spec={v["s1"]}></StackComponent>
        <StackText kind="h1" variant="" spec={v["s2"]}>{"A little closer."}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{v["s4"]}</StackText>
        <StackButton kind="button" variant="" spec={v["s5"]}>{"Explore again"}</StackButton>
        <StackButton kind="button" variant="quiet" spec={v["s6"]}>{"Change filters"}</StackButton></StackLayout>
    );
}

def:pub jobs_10(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="jobs-toast" spec={v["s0"]}>
        <StackComponent kind="Check" variant="" spec={v["s1"]}></StackComponent>{v["s2"]}</StackLayout>
    );
}

def:pub jobs_12(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub jobs_11(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackComponent kind="Icon" variant="" spec={v["s1"]}></StackComponent>
        <StackLayout kind="span" variant="" spec={v["s2"]}>{v["s3"]}</StackLayout>{v["s4"]}</StackButton>
    );
}

def:pub jobs_15(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>{v["s1"]}</StackButton>
    );
}

def:pub jobs_16(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>{v["s1"]}</StackButton>
    );
}

def:pub jobs_14(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="span" variant="sheet-eyebrow" spec={v["s0"]}>{"MAKE IT YOURS"}</StackLayout>
    <StackText kind="h2" variant="" spec={v["s1"]}>{"Find your kind of work."}</StackText>
    <StackText kind="p" variant="" spec={v["s2"]}>{"A few preferences for your next chapter."}</StackText>
    <StackLayout kind="fieldset" variant="" spec={v["s3"]}>
        <StackText kind="legend" variant="" spec={v["s4"]}>{"Opportunity"}</StackText>{v["s5"]}</StackLayout>
    <StackLayout kind="fieldset" variant="" spec={v["s6"]}>
        <StackText kind="legend" variant="" spec={v["s7"]}>{"Where you work"}</StackText>{v["s8"]}</StackLayout>
    <StackButton kind="button" variant="sheet-primary" spec={v["s9"]}>{"Show opportunities"}</StackButton></StackFragment>
    );
}

def:pub jobs_17(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="h2" variant="" spec={v["s0"]}>{"Your Stack."}</StackText>
    <StackButton kind="button" variant="sheet-menu-item" spec={v["s1"]}>{"Profile & preferences "}
        <StackComponent kind="ArrowUpRight" variant="" spec={v["s2"]}></StackComponent></StackButton>
    <StackButton kind="button" variant="sheet-menu-item" spec={v["s3"]}>{"Applications "}
        <StackComponent kind="ArrowUpRight" variant="" spec={v["s4"]}></StackComponent></StackButton>
    <StackText kind="p" variant="" spec={v["s5"]}>{v["s6"]}{" saved in this preview session."}</StackText></StackFragment>
    );
}

def:pub jobs_19(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub jobs_20(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="li" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub jobs_21(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub jobs_18(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="span" variant="sheet-eyebrow" spec={v["s0"]}>{v["s1"]}{" · "}{v["s2"]}</StackLayout>
    <StackText kind="h2" variant="" spec={v["s3"]}>{v["s4"]}</StackText>
    <StackText kind="p" variant="" spec={v["s5"]}>{v["s6"]}</StackText>
    <StackText kind="p" variant="" spec={v["s7"]}>{v["s8"]}
        <StackLayout kind="br" variant="" spec={v["s9"]}></StackLayout>{v["s10"]}{" · "}{v["s11"]}
        <StackLayout kind="br" variant="" spec={v["s12"]}></StackLayout>{v["s13"]}</StackText>
    <StackText kind="h3" variant="" spec={v["s14"]}>{"What you’ll do"}</StackText>
    <StackLayout kind="ul" variant="" spec={v["s15"]}>{v["s16"]}</StackLayout>
    <StackText kind="h3" variant="" spec={v["s17"]}>{"What you bring"}</StackText>
    <StackLayout kind="ul" variant="" spec={v["s18"]}>{v["s19"]}</StackLayout>
    <StackLayout kind="div" variant="opportunity-tags" spec={v["s20"]}>{v["s21"]}</StackLayout>
    <StackText kind="p" variant="sample-disclosure" spec={v["s22"]}>{"Sample opportunity for design review."}</StackText>
    <StackButton kind="button" variant="sheet-primary" spec={v["s23"]}>{"Save opportunity "}
        <StackComponent kind="Bookmark" variant="" spec={v["s24"]}></StackComponent></StackButton></StackFragment>
    );
}

def:pub jobs_13(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="jobs-sheet-backdrop" spec={v["s0"]}>
        <StackLayout kind="section" variant="jobs-sheet" spec={v["s1"]}>
            <StackLayout kind="div" variant="sheet-handle" spec={v["s2"]}></StackLayout>
            <StackButton kind="button" variant="sheet-close" spec={v["s3"]}>
                <StackComponent kind="X" variant="" spec={v["s4"]}></StackComponent></StackButton>{v["s5"]}</StackLayout></StackLayout>
    );
}

def:pub jobs_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="" spec={v["s0"]}>
        <StackLayout kind="header" variant="jobs-header" spec={v["s1"]}>
            <StackButton kind="button" variant="" spec={v["s2"]}>
                <StackComponent kind="Menu" variant="" spec={v["s3"]}></StackComponent></StackButton>
            <StackLayout kind="span" variant="jobs-wordmark" spec={v["s4"]}>{"stack"}
                <StackLayout kind="span" variant="" spec={v["s5"]}>{"."}</StackLayout></StackLayout>
            <StackLayout kind="div" variant="" spec={v["s6"]}>
                <StackButton kind="button" variant="" spec={v["s7"]}>
                    <StackComponent kind="Undo2" variant="" spec={v["s8"]}></StackComponent></StackButton>
                <StackButton kind="button" variant="" spec={v["s9"]}>
                    <StackComponent kind="SlidersHorizontal" variant="" spec={v["s10"]}></StackComponent>{v["s11"]}</StackButton></StackLayout></StackLayout>
        <StackScroll kind="main" variant="jobs-deck" spec={v["s12"]}>{v["s13"]}{v["s14"]}{v["s15"]}</StackScroll>
        <StackLayout kind="nav" variant="jobs-nav" spec={v["s16"]}>{v["s17"]}</StackLayout>{v["s18"]}</StackLayout>
    );
}
