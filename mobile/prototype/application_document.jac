# Shared native view source, migrated from prototype/application-document.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub application_document_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub application_document_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackDocument kind="iframe" variant="" spec={v["s0"]}></StackDocument>
    );
}

def:pub application_document_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{"Opening PDF…"}</StackText>
    );
}

def:pub application_document_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="" spec={v["s0"]}>
        <StackText kind="h4" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{v["s4"]}</StackText></StackLayout>
    );
}

def:pub application_document_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="article" variant="application-paper" spec={v["s0"]}>
        <StackText kind="h3" variant="" spec={v["s1"]}>{v["s2"]}</StackText>{v["s3"]}</StackLayout>
    );
}

def:pub application_document_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="" spec={v["s0"]}>
        <StackText kind="h4" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{v["s4"]}</StackText></StackLayout>
    );
}

def:pub application_document_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="application-muted" spec={v["s0"]}>{"Mock document preview. The original PDF is unchanged; no new PDF is generated."}</StackText>{v["s1"]}</StackFragment>
    );
}

def:pub application_document_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="application-document" spec={v["s0"]}>
        <StackButton kind="button" variant="application-secondary" spec={v["s1"]}>{"Close document preview"}</StackButton>
        <StackText kind="h3" variant="" spec={v["s2"]}>{v["s3"]}</StackText>{v["s4"]}{v["s5"]}</StackLayout>
    );
}
