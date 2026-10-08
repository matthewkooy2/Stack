# Shared native view source, migrated from prototype/applications.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub applications_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="jobs-preview applications-preview" spec={v["s0"]}>
        <StackComponent kind="ApplicationDetail" variant="" spec={v["s1"]}></StackComponent></StackLayout>
    );
}

def:pub applications_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackComponent kind="Search" variant="" spec={v["s1"]}></StackComponent></StackButton>
    );
}

def:pub applications_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub applications_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="ApplicationCalendar" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub applications_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub applications_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="label" variant="application-search" spec={v["s0"]}>
        <StackComponent kind="Search" variant="" spec={v["s1"]}></StackComponent>
        <StackInput kind="input" variant="" spec={v["s2"]}></StackInput></StackLayout>
    );
}

def:pub applications_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="jobs-loading-announcement" spec={v["s0"]}>{"Loading applications"}</StackLayout>
    );
}

def:pub applications_10(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="application-row" spec={v["s0"]}>
        <StackLayout kind="div" variant="" spec={v["s1"]}>{v["s2"]}</StackLayout>
        <StackLayout kind="div" variant="application-row-copy" spec={v["s3"]}>
            <StackText kind="strong" variant="" spec={v["s4"]}>{v["s5"]}</StackText>
            <StackText kind="h3" variant="" spec={v["s6"]}>{v["s7"]}</StackText>
            <StackLayout kind="span" variant="" spec={v["s8"]}>{v["s9"]}</StackLayout></StackLayout>
        <StackComponent kind="ChevronRight" variant="" spec={v["s10"]}></StackComponent></StackButton>
    );
}

def:pub applications_11(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="applications-empty" spec={v["s0"]}>
        <StackComponent kind="BriefcaseBusiness" variant="" spec={v["s1"]}></StackComponent>
        <StackText kind="h3" variant="" spec={v["s2"]}>{v["s3"]}</StackText>
        <StackText kind="p" variant="" spec={v["s4"]}>{v["s5"]}</StackText>
        <StackButton kind="button" variant="" spec={v["s6"]}>{v["s7"]}</StackButton></StackLayout>
    );
}

def:pub applications_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackScroll kind="main" variant="applications-scroll" spec={v["s0"]}>
        <StackLayout kind="div" variant="applications-intro" spec={v["s1"]}>
            <StackText kind="h1" variant="" spec={v["s2"]}>{"Applications"}</StackText>
            <StackLayout kind="div" variant="application-view-actions" spec={v["s3"]}>
                <StackButton kind="button" variant="application-filter-trigger" spec={v["s4"]}>
                    <StackComponent kind="CalendarDays" variant="" spec={v["s5"]}></StackComponent></StackButton>
                <StackButton kind="button" variant="application-filter-trigger" spec={v["s6"]}>
                    <StackComponent kind="SlidersHorizontal" variant="" spec={v["s7"]}></StackComponent>{v["s8"]}</StackButton></StackLayout></StackLayout>{v["s9"]}{v["s10"]}
        <StackLayout kind="div" variant="application-list" spec={v["s11"]}>{v["s12"]}</StackLayout>{v["s13"]}</StackScroll>
    );
}

def:pub applications_13(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub applications_12(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackComponent kind="Icon" variant="" spec={v["s1"]}></StackComponent>
        <StackLayout kind="span" variant="" spec={v["s2"]}>{v["s3"]}</StackLayout>{v["s4"]}</StackButton>
    );
}

def:pub applications_14(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="jobs-toast" spec={v["s0"]}>
        <StackComponent kind="Check" variant="" spec={v["s1"]}></StackComponent>{v["s2"]}</StackLayout>
    );
}

def:pub applications_17(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Check" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub applications_16(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackLayout kind="span" variant="" spec={v["s1"]}>{v["s2"]}</StackLayout>{v["s3"]}</StackButton>
    );
}

def:pub applications_15(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="jobs-sheet-backdrop" spec={v["s0"]}>
        <StackLayout kind="section" variant="jobs-sheet application-filter-sheet" spec={v["s1"]}>
            <StackLayout kind="div" variant="sheet-handle" spec={v["s2"]}></StackLayout>
            <StackButton kind="button" variant="sheet-close" spec={v["s3"]}>
                <StackComponent kind="X" variant="" spec={v["s4"]}></StackComponent></StackButton>
            <StackText kind="h2" variant="" spec={v["s5"]}>{"Filter applications"}</StackText>
            <StackText kind="p" variant="" spec={v["s6"]}>{"Status"}</StackText>
            <StackLayout kind="div" variant="application-filter-options" spec={v["s7"]}>{v["s8"]}</StackLayout></StackLayout></StackLayout>
    );
}

def:pub applications_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="" spec={v["s0"]}>
        <StackLayout kind="header" variant="jobs-header" spec={v["s1"]}>
            <StackButton kind="button" variant="" spec={v["s2"]}>
                <StackComponent kind="Menu" variant="" spec={v["s3"]}></StackComponent></StackButton>
            <StackLayout kind="span" variant="jobs-wordmark" spec={v["s4"]}>{"stack"}
                <StackLayout kind="span" variant="" spec={v["s5"]}>{"."}</StackLayout></StackLayout>{v["s6"]}</StackLayout>{v["s7"]}
        <StackLayout kind="nav" variant="jobs-nav" spec={v["s8"]}>{v["s9"]}</StackLayout>{v["s10"]}{v["s11"]}</StackLayout>
    );
}
