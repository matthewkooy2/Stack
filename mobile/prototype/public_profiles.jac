# Shared native view source, migrated from prototype/public-profiles.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub public_profiles_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="jobs-loading-announcement" spec={v["s0"]}>{"Loading profile details"}</StackLayout>
    );
}

def:pub public_profiles_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="profile-channel" spec={v["s0"]}>
        <StackLayout kind="span" variant="" spec={v["s1"]}>{v["s2"]}</StackLayout>
        <StackLayout kind="span" variant="" spec={v["s3"]}>
            <StackText kind="strong" variant="" spec={v["s4"]}>{v["s5"]}</StackText>
            <StackText kind="small" variant="" spec={v["s6"]}>{v["s7"]}</StackText></StackLayout>
        <StackComponent kind="ChevronRight" variant="" spec={v["s8"]}></StackComponent></StackButton>
    );
}

def:pub public_profiles_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub public_profiles_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="profile-field-row" spec={v["s0"]}>
        <StackButton kind="button" variant="profile-field-value" spec={v["s1"]}>
            <StackLayout kind="span" variant="" spec={v["s2"]}>{v["s3"]}</StackLayout>
            <StackText kind="strong" variant="" spec={v["s4"]}>{v["s5"]}</StackText></StackButton>
        <StackButton kind="button" variant="profile-field-pencil" spec={v["s6"]}>
            <StackComponent kind="Pencil" variant="" spec={v["s7"]}></StackComponent></StackButton></StackLayout>
    );
}

def:pub public_profiles_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="profile-fields" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub public_profiles_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="profile-field-section" spec={v["s0"]}>
        <StackButton kind="button" variant="profile-section-heading" spec={v["s1"]}>
            <StackLayout kind="span" variant="" spec={v["s2"]}>{v["s3"]}</StackLayout>
            <StackComponent kind="ChevronDown" variant="" spec={v["s4"]}></StackComponent></StackButton>{v["s5"]}</StackLayout>
    );
}

def:pub public_profiles_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="jobs-sheet-backdrop" spec={v["s0"]}>
        <StackLayout kind="section" variant="jobs-sheet application-detail profile-field-editor" spec={v["s1"]}>
            <StackLayout kind="div" variant="sheet-handle" spec={v["s2"]}></StackLayout>
            <StackButton kind="button" variant="sheet-close" spec={v["s3"]}>
                <StackComponent kind="X" variant="" spec={v["s4"]}></StackComponent></StackButton>
            <StackLayout kind="span" variant="sheet-eyebrow" spec={v["s5"]}>{v["s6"]}</StackLayout>
            <StackText kind="h2" variant="" spec={v["s7"]}>{v["s8"]}</StackText>
            <StackLayout kind="label" variant="profile-editor-label" spec={v["s9"]}>{v["s10"]}
                <StackInput kind="textarea" variant="" spec={v["s11"]}></StackInput></StackLayout>
            <StackButton kind="button" variant="sheet-primary" spec={v["s12"]}>{"Save "}
                <StackComponent kind="Check" variant="" spec={v["s13"]}></StackComponent></StackButton>
            <StackText kind="p" variant="application-detail-hint" spec={v["s14"]}>{"Preview only · Your public profile stays unchanged."}</StackText></StackLayout></StackLayout>
    );
}

def:pub public_profiles_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackScroll kind="main" variant="applications-scroll public-profiles public-profile-fields" spec={v["s0"]}>
        <StackLayout kind="div" variant="calendar-heading" spec={v["s1"]}>
            <StackButton kind="button" variant="" spec={v["s2"]}>
                <StackComponent kind="ArrowLeft" variant="" spec={v["s3"]}></StackComponent></StackButton>
            <StackText kind="h1" variant="" spec={v["s4"]}>{v["s5"]}</StackText></StackLayout>{v["s6"]}{v["s7"]}{v["s8"]}</StackScroll>
    );
}
