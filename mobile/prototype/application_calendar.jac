# Shared native view source, migrated from prototype/application-calendar.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub application_calendar_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="jobs-loading-announcement" spec={v["s0"]}>{"Loading calendar activity"}</StackLayout>
    );
}

def:pub application_calendar_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="calendar-weekday" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub application_calendar_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub application_calendar_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="small" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub application_calendar_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub application_calendar_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackLayout kind="span" variant="" spec={v["s1"]}>{v["s2"]}</StackLayout>{v["s3"]}{v["s4"]}</StackButton>
    );
}

def:pub application_calendar_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="" spec={v["s0"]}>{"Today"}</StackLayout>
    );
}

def:pub application_calendar_10(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="calendar-detail-placeholder" spec={v["s0"]}>
        <StackLayout kind="i" variant="" spec={v["s1"]}></StackLayout>
        <StackLayout kind="i" variant="" spec={v["s2"]}></StackLayout>
        <StackLayout kind="i" variant="" spec={v["s3"]}></StackLayout></StackLayout>
    );
}

def:pub application_calendar_12(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="calendar-event" spec={v["s0"]}>
        <StackComponent kind="CalendarDays" variant="" spec={v["s1"]}></StackComponent>
        <StackLayout kind="div" variant="" spec={v["s2"]}>
            <StackText kind="strong" variant="" spec={v["s3"]}>{v["s4"]}{" · "}{v["s5"]}</StackText>
            <StackText kind="p" variant="" spec={v["s6"]}>{v["s7"]}</StackText></StackLayout></StackLayout>
    );
}

def:pub application_calendar_13(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="calendar-submission" spec={v["s0"]}>
        <StackComponent kind="Check" variant="" spec={v["s1"]}></StackComponent>
        <StackLayout kind="span" variant="" spec={v["s2"]}>{v["s3"]}</StackLayout></StackLayout>
    );
}

def:pub application_calendar_11(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>{v["s0"]}
    <StackText kind="p" variant="calendar-day-count" spec={v["s1"]}>{v["s2"]}</StackText>{v["s3"]}</StackFragment>
    );
}

def:pub application_calendar_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="calendar-day-detail" spec={v["s0"]}>
        <StackText kind="h3" variant="" spec={v["s1"]}>{v["s2"]}{v["s3"]}
            <StackButton kind="button" variant="" spec={v["s4"]}>{"×"}</StackButton></StackText>{v["s5"]}</StackLayout>
    );
}

def:pub application_calendar_14(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Check" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub application_calendar_15(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="ChevronRight" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub application_calendar_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackScroll kind="main" variant="" spec={v["s0"]}>{v["s1"]}
        <StackLayout kind="div" variant="calendar-heading" spec={v["s2"]}>
            <StackButton kind="button" variant="" spec={v["s3"]}>
                <StackComponent kind="ArrowLeft" variant="" spec={v["s4"]}></StackComponent></StackButton>
            <StackText kind="h1" variant="" spec={v["s5"]}>{"Calendar"}</StackText>
            <StackButton kind="button" variant="calendar-today" spec={v["s6"]}>{"Today"}</StackButton></StackLayout>
        <StackLayout kind="div" variant="calendar-month" spec={v["s7"]}>
            <StackText kind="h2" variant="" spec={v["s8"]}>{v["s9"]}</StackText>
            <StackLayout kind="div" variant="" spec={v["s10"]}>
                <StackButton kind="button" variant="" spec={v["s11"]}>
                    <StackComponent kind="ChevronLeft" variant="" spec={v["s12"]}></StackComponent></StackButton>
                <StackButton kind="button" variant="" spec={v["s13"]}>
                    <StackComponent kind="ChevronRight" variant="" spec={v["s14"]}></StackComponent></StackButton></StackLayout></StackLayout>
        <StackLayout kind="div" variant="calendar-grid" spec={v["s15"]}>{v["s16"]}{v["s17"]}{v["s18"]}</StackLayout>
        <StackLayout kind="div" variant="calendar-summary" spec={v["s19"]}>
            <StackLayout kind="span" variant="" spec={v["s20"]}>
                <StackComponent kind="Flame" variant="" spec={v["s21"]}></StackComponent>
                <StackText kind="strong" variant="" spec={v["s22"]}>{v["s23"]}</StackText>{" day streak"}</StackLayout>
            <StackLayout kind="span" variant="" spec={v["s24"]}>
                <StackText kind="strong" variant="" spec={v["s25"]}>{v["s26"]}</StackText>{" applications this month"}</StackLayout></StackLayout>{v["s27"]}
        <StackButton kind="button" variant="calendar-connect" spec={v["s28"]}>
            <StackLayout kind="span" variant="calendar-google" spec={v["s29"]}>{"G"}</StackLayout>
            <StackLayout kind="span" variant="" spec={v["s30"]}>{v["s31"]}
                <StackText kind="small" variant="" spec={v["s32"]}>{"Demo"}</StackText></StackLayout>{v["s33"]}</StackButton></StackScroll>
    );
}
