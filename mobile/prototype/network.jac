# Shared native view source, migrated from prototype/network.jsx.
import from "./controls.js" { StackLayout, StackText, StackButton, StackInput, StackSelect, StackOption, StackDisclosure, StackSummary, StackForm, StackDocument, StackScroll, StackComponent, StackFragment }

def:pub network_2(v: dict[str, any]) -> JsxElement {
    return (
    <StackInput kind="textarea" variant="" spec={v["s0"]}></StackInput>
    );
}

def:pub network_3(v: dict[str, any]) -> JsxElement {
    return (
    <StackInput kind="input" variant="" spec={v["s0"]}></StackInput>
    );
}

def:pub network_1(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="label" variant="net-field" spec={v["s0"]}>{v["s1"]}
        <StackLayout kind="span" variant="" spec={v["s2"]}>{v["s3"]}</StackLayout></StackLayout>
    );
}

def:pub network_6(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Icon" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub network_5(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub network_4(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="net-entry" spec={v["s0"]}>{v["s1"]}
        <StackLayout kind="span" variant="net-entry-copy" spec={v["s2"]}>
            <StackText kind="strong" variant="" spec={v["s3"]}>{v["s4"]}</StackText>
            <StackText kind="small" variant="" spec={v["s5"]}>{v["s6"]}</StackText></StackLayout>
        <StackComponent kind="ChevronRight" variant="" spec={v["s7"]}></StackComponent></StackButton>
    );
}

def:pub network_7(v: dict[str, any]) -> JsxElement {
    return (
    <StackDisclosure kind="details" variant="net-fold" spec={v["s0"]}>
        <StackSummary kind="summary" variant="" spec={v["s1"]}>{v["s2"]}
            <StackComponent kind="ChevronDown" variant="" spec={v["s3"]}></StackComponent></StackSummary>{v["s4"]}</StackDisclosure>
    );
}

def:pub network_9(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-inline-editor" spec={v["s0"]}>
        <StackComponent kind="Field" variant="" spec={v["s1"]}></StackComponent>
        <StackButton kind="button" variant="net-secondary" spec={v["s2"]}>{"Done"}</StackButton></StackLayout>
    );
}

def:pub network_10(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="profile-field-row" spec={v["s0"]}>
        <StackButton kind="button" variant="profile-field-value" spec={v["s1"]}>
            <StackLayout kind="span" variant="" spec={v["s2"]}>{v["s3"]}</StackLayout>
            <StackText kind="strong" variant="" spec={v["s4"]}>{v["s5"]}</StackText></StackButton>
        <StackButton kind="button" variant="profile-field-pencil" spec={v["s6"]}>
            <StackComponent kind="Pencil" variant="" spec={v["s7"]}></StackComponent></StackButton></StackLayout>
    );
}

def:pub network_8(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub network_11(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-empty" spec={v["s0"]}>
        <StackComponent kind="Users" variant="" spec={v["s1"]}></StackComponent>
        <StackText kind="h2" variant="" spec={v["s2"]}>{v["s3"]}</StackText>
        <StackText kind="p" variant="" spec={v["s4"]}>{v["s5"]}</StackText></StackLayout>
    );
}

def:pub network_12(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="span" variant="jobs-loading-announcement" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub network_13(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-error" spec={v["s0"]}>
        <StackText kind="strong" variant="" spec={v["s1"]}>{"Connection needed"}</StackText>
        <StackText kind="p" variant="" spec={v["s2"]}>{"Configure a model and the required browser or email connection before continuing."}</StackText>
        <StackButton kind="button" variant="net-secondary" spec={v["s3"]}>{"Use configured demo"}</StackButton></StackLayout>
    );
}

def:pub network_15(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="PublicProfiles" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub network_17(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackComponent kind="ArrowLeft" variant="" spec={v["s1"]}></StackComponent></StackButton>
    );
}

def:pub network_18(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="net-error" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub network_19(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="net-notice" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub network_20(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackComponent kind="Entry" variant="" spec={v["s0"]}></StackComponent>
    <StackComponent kind="Entry" variant="" spec={v["s1"]}></StackComponent>
    <StackComponent kind="Entry" variant="" spec={v["s2"]}></StackComponent>
    <StackComponent kind="Entry" variant="" spec={v["s3"]}></StackComponent></StackFragment>
    );
}

def:pub network_22(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Field" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub network_23(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Entry" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub network_24(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Entry" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub network_25(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Empty" variant="" spec={v["s0"]}>{"Add your first contact or import a list."}</StackComponent>
    );
}

def:pub network_26(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Empty" variant="" spec={v["s0"]}>{"Try another name, company, or email."}</StackComponent>
    );
}

def:pub network_21(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="div" variant="net-actions" spec={v["s0"]}>
        <StackButton kind="button" variant="sheet-primary" spec={v["s1"]}>
            <StackComponent kind="Plus" variant="" spec={v["s2"]}></StackComponent>{"Add contact"}</StackButton>
        <StackButton kind="button" variant="net-secondary" spec={v["s3"]}>{"Import CSV"}</StackButton>
        <StackButton kind="button" variant="net-icon-action" spec={v["s4"]}>
            <StackComponent kind="Search" variant="" spec={v["s5"]}></StackComponent></StackButton></StackLayout>{v["s6"]}
    <StackComponent kind="Announcement" variant="" spec={v["s7"]}></StackComponent>{v["s8"]}{v["s9"]}{v["s10"]}{v["s11"]}</StackFragment>
    );
}

def:pub network_27(v: dict[str, any]) -> JsxElement {
    return (
    <StackForm kind="form" variant="" spec={v["s0"]}>
        <StackComponent kind="Field" variant="" spec={v["s1"]}></StackComponent>
        <StackComponent kind="Field" variant="" spec={v["s2"]}></StackComponent>
        <StackComponent kind="Field" variant="" spec={v["s3"]}></StackComponent>
        <StackComponent kind="Fold" variant="" spec={v["s4"]}>
            <StackComponent kind="Field" variant="" spec={v["s5"]}></StackComponent>
            <StackComponent kind="Field" variant="" spec={v["s6"]}></StackComponent></StackComponent>
        <StackButton kind="button" variant="sheet-primary" spec={v["s7"]}>{"Save contact"}</StackButton>
        <StackText kind="p" variant="net-caption" spec={v["s8"]}>{"Your draft is kept when you leave this page."}</StackText></StackForm>
    );
}

def:pub network_29(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="net-intro" spec={v["s0"]}>{"Paste CSV or email addresses to review."}</StackText>
    <StackComponent kind="Field" variant="" spec={v["s1"]}></StackComponent>
    <StackLayout kind="div" variant="net-import-meta" spec={v["s2"]}>
        <StackLayout kind="span" variant="" spec={v["s3"]}>{"Up to 200 contacts · 200 KB"}</StackLayout>
        <StackButton kind="button" variant="net-secondary" spec={v["s4"]}>{"Use sample"}</StackButton></StackLayout>
    <StackButton kind="button" variant="sheet-primary" spec={v["s5"]}>{v["s6"]}</StackButton>
    <StackText kind="p" variant="net-caption" spec={v["s7"]}>{"CSV accepts name, email, company, relationship, and source_url. Quoted values and reordered columns are supported."}</StackText></StackFragment>
    );
}

def:pub network_32(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="" spec={v["s0"]}>{v["s1"]}</StackText>
    );
}

def:pub network_31(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-contact-review" spec={v["s0"]}>
        <StackLayout kind="span" variant="net-entry-mark" spec={v["s1"]}>{v["s2"]}</StackLayout>
        <StackLayout kind="div" variant="" spec={v["s3"]}>
            <StackText kind="strong" variant="" spec={v["s4"]}>{v["s5"]}</StackText>
            <StackText kind="p" variant="" spec={v["s6"]}>{v["s7"]}</StackText>{v["s8"]}</StackLayout></StackLayout>
    );
}

def:pub network_33(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="sheet-primary" spec={v["s0"]}>{"Import contacts"}</StackButton>
    );
}

def:pub network_34(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Empty" variant="" spec={v["s0"]}>{"No new contacts to import."}</StackComponent>
    );
}

def:pub network_30(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="div" variant="net-section-title" spec={v["s0"]}>
        <StackText kind="h2" variant="" spec={v["s1"]}>{v["s2"]}{" new contacts"}</StackText>
        <StackButton kind="button" variant="net-secondary" spec={v["s3"]}>{"Edit CSV"}</StackButton></StackLayout>
    <StackText kind="p" variant="net-muted" spec={v["s4"]}>{"Duplicates are skipped. Imported contacts remain unselected until you choose them."}</StackText>{v["s5"]}{v["s6"]}</StackFragment>
    );
}

def:pub network_28(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>{v["s0"]}
    <StackText kind="p" variant="net-caption" spec={v["s1"]}>{"Simulated import · Nothing is uploaded."}</StackText></StackFragment>
    );
}

def:pub network_37(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="a" variant="net-source" spec={v["s0"]}>{"Research source"}</StackButton>
    );
}

def:pub network_36(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Fold" variant="" spec={v["s0"]}>
        <StackText kind="p" variant="net-muted" spec={v["s1"]}>{v["s2"]}</StackText>{v["s3"]}</StackComponent>
    );
}

def:pub network_38(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="sheet-primary" spec={v["s0"]}>{"Select for outreach"}</StackButton>
    );
}

def:pub network_39(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Entry" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub network_40(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="net-muted" spec={v["s0"]}>{"Add a verified email to draft outreach."}</StackText>
    );
}

def:pub network_41(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="net-secondary" spec={v["s0"]}>{"Stop outreach and follow-ups"}</StackButton>
    );
}

def:pub network_42(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Entry" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub network_43(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="net-muted" spec={v["s0"]}>{"No outreach yet."}</StackText>
    );
}

def:pub network_35(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="div" variant="net-contact-summary" spec={v["s0"]}>
        <StackLayout kind="span" variant="net-entry-mark" spec={v["s1"]}>{v["s2"]}</StackLayout>
        <StackLayout kind="div" variant="" spec={v["s3"]}>
            <StackText kind="p" variant="" spec={v["s4"]}>{v["s5"]}</StackText>
            <StackText kind="small" variant="" spec={v["s6"]}>{v["s7"]}</StackText></StackLayout>
        <StackButton kind="button" variant="net-icon-action" spec={v["s8"]}>
            <StackComponent kind="Pencil" variant="" spec={v["s9"]}></StackComponent></StackButton></StackLayout>
    <StackText kind="p" variant="net-status" spec={v["s10"]}>{v["s11"]}</StackText>{v["s12"]}{v["s13"]}{v["s14"]}{v["s15"]}{v["s16"]}{v["s17"]}
    <StackComponent kind="Fold" variant="" spec={v["s18"]}>
        <StackText kind="p" variant="net-muted" spec={v["s19"]}>{"Applies to selected contacts. Every follow-up is drafted for its own approval and stops on reply."}</StackText>
        <StackComponent kind="Field" variant="" spec={v["s20"]}></StackComponent>
        <StackComponent kind="Field" variant="" spec={v["s21"]}></StackComponent></StackComponent>
    <StackComponent kind="Fold" variant="" spec={v["s22"]}>
        <StackText kind="p" variant="net-muted" spec={v["s23"]}>{"Follow-ups sent: "}{v["s24"]}{v["s25"]}</StackText>{v["s26"]}{v["s27"]}</StackComponent></StackFragment>
    );
}

def:pub network_45(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-error" spec={v["s0"]}>{v["s1"]}</StackLayout>
    );
}

def:pub network_46(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="sheet-primary" spec={v["s0"]}>{"Retry draft"}</StackButton>
    );
}

def:pub network_47(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-recovery" spec={v["s0"]}>
        <StackText kind="p" variant="net-muted" spec={v["s1"]}>{"Confirm the simulated result before retrying. This prevents duplicate email."}</StackText>
        <StackButton kind="button" variant="net-secondary" spec={v["s2"]}>{"Confirm sent"}</StackButton>
        <StackButton kind="button" variant="net-secondary" spec={v["s3"]}>{"Confirm not sent"}</StackButton></StackLayout>
    );
}

def:pub network_48(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="net-muted" spec={v["s0"]}>{"This draft was cancelled. Nothing more will be sent."}</StackText>
    );
}

def:pub network_49(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Fold" variant="" spec={v["s0"]}>
        <StackComponent kind="Announcement" variant="" spec={v["s1"]}></StackComponent>
        <StackComponent kind="Editable" variant="" spec={v["s2"]}></StackComponent>
        <StackComponent kind="Editable" variant="" spec={v["s3"]}></StackComponent>
        <StackText kind="p" variant="net-caption" spec={v["s4"]}>{"Edits are saved as you type."}</StackText></StackComponent>
    );
}

def:pub network_50(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackButton kind="button" variant="sheet-primary" spec={v["s0"]}>{"Approve & simulate send"}</StackButton>
    <StackButton kind="button" variant="net-secondary" spec={v["s1"]}>{"Cancel draft"}</StackButton></StackFragment>
    );
}

def:pub network_51(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="net-notice" spec={v["s0"]}>{"Email approved and delivery simulated. Any next follow-up will need a separate approval."}</StackText>
    );
}

def:pub network_44(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="net-intro" spec={v["s0"]}>{"To "}{v["s1"]}
        <StackText kind="small" variant="net-recipient" spec={v["s2"]}>{v["s3"]}</StackText></StackText>
    <StackText kind="p" variant="net-status" spec={v["s4"]}>{v["s5"]}</StackText>{v["s6"]}{v["s7"]}{v["s8"]}{v["s9"]}{v["s10"]}{v["s11"]}
    <StackText kind="p" variant="net-caption" spec={v["s12"]}>{"Preview only · No real email is sent."}</StackText></StackFragment>
    );
}

def:pub network_54(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="net-secondary" spec={v["s0"]}>{v["s1"]}</StackButton>
    );
}

def:pub network_53(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="fieldset" variant="net-filters" spec={v["s0"]}>
        <StackText kind="legend" variant="" spec={v["s1"]}>{"People"}</StackText>{v["s2"]}</StackLayout>
    );
}

def:pub network_55(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Field" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub network_56(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-person-row" spec={v["s0"]}>
        <StackComponent kind="Entry" variant="" spec={v["s1"]}></StackComponent>
        <StackButton kind="button" variant="net-icon-action" spec={v["s2"]}>
            <StackComponent kind="Bookmark" variant="" spec={v["s3"]}></StackComponent></StackButton></StackLayout>
    );
}

def:pub network_57(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Empty" variant="" spec={v["s0"]}>{"Try Discover to find someone to save."}</StackComponent>
    );
}

def:pub network_52(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="div" variant="net-actions" spec={v["s0"]}>
        <StackButton kind="button" variant="net-secondary" spec={v["s1"]}>{"Discover"}</StackButton>
        <StackButton kind="button" variant="net-secondary" spec={v["s2"]}>{"Saved"}</StackButton>
        <StackButton kind="button" variant="net-icon-action" spec={v["s3"]}>
            <StackComponent kind="Search" variant="" spec={v["s4"]}></StackComponent></StackButton>
        <StackButton kind="button" variant="net-icon-action" spec={v["s5"]}>
            <StackComponent kind="SlidersHorizontal" variant="" spec={v["s6"]}></StackComponent></StackButton></StackLayout>{v["s7"]}{v["s8"]}
    <StackText kind="p" variant="net-caption" spec={v["s9"]}>{"Fictional people · Separate from your outreach contacts."}</StackText>
    <StackComponent kind="Announcement" variant="" spec={v["s10"]}></StackComponent>{v["s11"]}{v["s12"]}</StackFragment>
    );
}

def:pub network_58(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackComponent kind="Announcement" variant="" spec={v["s0"]}></StackComponent>
    <StackText kind="p" variant="" spec={v["s1"]}>{v["s2"]}{" · "}{v["s3"]}
        <StackText kind="small" variant="net-recipient" spec={v["s4"]}>{v["s5"]}</StackText></StackText>
    <StackText kind="p" variant="net-caption" spec={v["s6"]}>{"Fictional person · Example only"}</StackText>
    <StackText kind="p" variant="" spec={v["s7"]}>{v["s8"]}</StackText>
    <StackText kind="p" variant="" spec={v["s9"]}>{v["s10"]}</StackText>
    <StackButton kind="button" variant="net-secondary" spec={v["s11"]}>{v["s12"]}</StackButton>
    <StackComponent kind="Entry" variant="" spec={v["s13"]}></StackComponent>
    <StackComponent kind="Fold" variant="" spec={v["s14"]}>
        <StackComponent kind="Editable" variant="" spec={v["s15"]}></StackComponent></StackComponent>
    <StackComponent kind="Fold" variant="" spec={v["s16"]}>
        <StackComponent kind="Editable" variant="" spec={v["s17"]}></StackComponent>
        <StackText kind="p" variant="net-caption" spec={v["s18"]}>{"Draft only · Sending is not enabled for fictional people."}</StackText></StackComponent></StackFragment>
    );
}

def:pub network_60(v: dict[str, any]) -> JsxElement {
    return (
    <StackForm kind="form" variant="net-reminder-form" spec={v["s0"]}>
        <StackComponent kind="Field" variant="" spec={v["s1"]}></StackComponent>
        <StackComponent kind="Field" variant="" spec={v["s2"]}></StackComponent>
        <StackButton kind="button" variant="sheet-primary" spec={v["s3"]}>{v["s4"]}</StackButton>
        <StackButton kind="button" variant="net-secondary" spec={v["s5"]}>{"Cancel"}</StackButton></StackForm>
    );
}

def:pub network_62(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="net-secondary" spec={v["s0"]}>{"Mark complete"}</StackButton>
    );
}

def:pub network_61(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-finding" spec={v["s0"]}>
        <StackText kind="strong" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{v["s4"]}{" · "}{v["s5"]}</StackText>
        <StackLayout kind="div" variant="net-actions" spec={v["s6"]}>{v["s7"]}
            <StackButton kind="button" variant="net-icon-action" spec={v["s8"]}>
                <StackComponent kind="Pencil" variant="" spec={v["s9"]}></StackComponent></StackButton>
            <StackButton kind="button" variant="net-icon-action" spec={v["s10"]}>
                <StackComponent kind="Trash2" variant="" spec={v["s11"]}></StackComponent></StackButton></StackLayout></StackLayout>
    );
}

def:pub network_63(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Empty" variant="" spec={v["s0"]}>{"Choose a time to reconnect."}</StackComponent>
    );
}

def:pub network_59(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="net-intro" spec={v["s0"]}>{v["s1"]}</StackText>
    <StackButton kind="button" variant="net-secondary" spec={v["s2"]}>
        <StackComponent kind="Plus" variant="" spec={v["s3"]}></StackComponent>{" Add reminder"}</StackButton>{v["s4"]}
    <StackComponent kind="Announcement" variant="" spec={v["s5"]}></StackComponent>{v["s6"]}{v["s7"]}
    <StackText kind="p" variant="net-caption" spec={v["s8"]}>{"Preview only · No device notification is scheduled."}</StackText></StackFragment>
    );
}

def:pub network_65(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="Entry" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub network_66(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="net-muted" spec={v["s0"]}>{"No reviews yet."}</StackText>
    );
}

def:pub network_64(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="net-intro" spec={v["s0"]}>{"Review your profile for the role you want."}</StackText>
    <StackComponent kind="Announcement" variant="" spec={v["s1"]}></StackComponent>
    <StackComponent kind="Field" variant="" spec={v["s2"]}></StackComponent>
    <StackComponent kind="Field" variant="" spec={v["s3"]}></StackComponent>
    <StackButton kind="button" variant="net-secondary" spec={v["s4"]}>{"Save profile details"}</StackButton>{v["s5"]}
    <StackButton kind="button" variant="sheet-primary" spec={v["s6"]}>{"Review my LinkedIn profile"}</StackButton>
    <StackText kind="p" variant="net-caption" spec={v["s7"]}>{"Simulated browser and sample profile · No LinkedIn account is accessed."}</StackText>
    <StackComponent kind="Fold" variant="" spec={v["s8"]}>{v["s9"]}{v["s10"]}</StackComponent></StackFragment>
    );
}

def:pub network_68(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-error" spec={v["s0"]}>
        <StackText kind="p" variant="" spec={v["s1"]}>{"The browser could not connect. Your profile details are safe."}</StackText>
        <StackButton kind="button" variant="net-secondary" spec={v["s2"]}>{"Refresh browser"}</StackButton></StackLayout>
    );
}

def:pub network_69(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackLayout kind="div" variant="net-browser-placeholder" spec={v["s0"]}>
        <StackLayout kind="span" variant="net-entry-mark" spec={v["s1"]}>{"in"}</StackLayout>
        <StackText kind="h2" variant="" spec={v["s2"]}>{"LinkedIn sign-in"}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{"This preview simulates the private browser. No credentials are requested."}</StackText></StackLayout>
    <StackLayout kind="label" variant="net-check" spec={v["s4"]}>
        <StackInput kind="input" variant="" spec={v["s5"]}></StackInput>{"I confirm this is my profile"}</StackLayout>
    <StackButton kind="button" variant="sheet-primary" spec={v["s6"]}>{"I’m signed in · Analyze my profile"}</StackButton></StackFragment>
    );
}

def:pub network_70(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-error" spec={v["s0"]}>
        <StackText kind="p" variant="" spec={v["s1"]}>{"The browser session expired. Your review details are safe."}</StackText>
        <StackButton kind="button" variant="net-secondary" spec={v["s2"]}>{"Open browser again"}</StackButton></StackLayout>
    );
}

def:pub network_71(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-error" spec={v["s0"]}>
        <StackText kind="p" variant="" spec={v["s1"]}>{"Analysis paused. The captured profile is retained; you do not need to sign in again."}</StackText>
        <StackButton kind="button" variant="net-secondary" spec={v["s2"]}>{"Retry analysis"}</StackButton></StackLayout>
    );
}

def:pub network_72(v: dict[str, any]) -> JsxElement {
    return (
    <StackComponent kind="LinkedInReport" variant="" spec={v["s0"]}></StackComponent>
    );
}

def:pub network_73(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="net-secondary" spec={v["s0"]}>{"Cancel review"}</StackButton>
    );
}

def:pub network_74(v: dict[str, any]) -> JsxElement {
    return (
    <StackText kind="p" variant="net-muted" spec={v["s0"]}>{"Review cancelled. Start a new review from LinkedIn review."}</StackText>
    );
}

def:pub network_67(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="net-intro" spec={v["s0"]}>{v["s1"]}
        <StackText kind="small" variant="net-recipient" spec={v["s2"]}>{v["s3"]}</StackText></StackText>
    <StackText kind="p" variant="net-status" spec={v["s4"]}>{v["s5"]}</StackText>{v["s6"]}{v["s7"]}{v["s8"]}{v["s9"]}{v["s10"]}{v["s11"]}{v["s12"]}</StackFragment>
    );
}

def:pub network_16(v: dict[str, any]) -> JsxElement {
    return (
    <StackScroll kind="main" variant="applications-scroll net-main" spec={v["s0"]}>
        <StackLayout kind="div" variant="calendar-heading" spec={v["s1"]}>{v["s2"]}
            <StackText kind="h1" variant="" spec={v["s3"]}>{v["s4"]}</StackText></StackLayout>{v["s5"]}{v["s6"]}{v["s7"]}{v["s8"]}{v["s9"]}{v["s10"]}{v["s11"]}{v["s12"]}{v["s13"]}{v["s14"]}{v["s15"]}{v["s16"]}{v["s17"]}</StackScroll>
    );
}

def:pub network_76(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="i" variant="" spec={v["s0"]}></StackLayout>
    );
}

def:pub network_75(v: dict[str, any]) -> JsxElement {
    return (
    <StackButton kind="button" variant="" spec={v["s0"]}>
        <StackComponent kind="Icon" variant="" spec={v["s1"]}></StackComponent>
        <StackLayout kind="span" variant="" spec={v["s2"]}>{v["s3"]}</StackLayout>{v["s4"]}</StackButton>
    );
}

def:pub network_14(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="section" variant="jobs-preview network-preview" spec={v["s0"]}>
        <StackComponent kind="PreviewControls" variant="" spec={v["s1"]}></StackComponent>
        <StackLayout kind="header" variant="jobs-header" spec={v["s2"]}>
            <StackButton kind="button" variant="" spec={v["s3"]}>
                <StackComponent kind="Menu" variant="" spec={v["s4"]}></StackComponent></StackButton>
            <StackLayout kind="span" variant="jobs-wordmark" spec={v["s5"]}>{"stack"}
                <StackLayout kind="span" variant="" spec={v["s6"]}>{"."}</StackLayout></StackLayout>
            <StackLayout kind="span" variant="" spec={v["s7"]}></StackLayout></StackLayout>{v["s8"]}
        <StackLayout kind="nav" variant="jobs-nav" spec={v["s9"]}>{v["s10"]}</StackLayout></StackLayout>
    );
}

def:pub network_78(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-rewrite" spec={v["s0"]}>
        <StackComponent kind="Editable" variant="" spec={v["s1"]}></StackComponent>
        <StackDisclosure kind="details" variant="net-evidence" spec={v["s2"]}>
            <StackSummary kind="summary" variant="" spec={v["s3"]}>{"Source quotation"}</StackSummary>
            <StackText kind="p" variant="" spec={v["s4"]}>{"“"}{v["s5"]}{"”"}</StackText></StackDisclosure>
        <StackLayout kind="label" variant="net-check" spec={v["s6"]}>
            <StackInput kind="input" variant="" spec={v["s7"]}></StackInput>{"Keep this rewrite"}</StackLayout></StackLayout>
    );
}

def:pub network_79(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackText kind="p" variant="net-notice" spec={v["s0"]}>{"Ready to apply yourself. Your live profile is unchanged."}</StackText>
    <StackButton kind="button" variant="net-secondary" spec={v["s1"]}>{"Copy approved rewrites"}</StackButton></StackFragment>
    );
}

def:pub network_finding(v: dict[str, any]) -> JsxElement {
    return (
    <StackLayout kind="div" variant="net-finding" spec={v["s0"]}>
        <StackText kind="strong" variant="" spec={v["s1"]}>{v["s2"]}</StackText>
        <StackText kind="p" variant="" spec={v["s3"]}>{"“"}{v["s4"]}{"”"}</StackText>
        <StackText kind="p" variant="" spec={v["s5"]}>{v["s6"]}</StackText></StackLayout>
    );
}

def:pub network_77(v: dict[str, any]) -> JsxElement {
    return (
    <StackFragment>
    <StackComponent kind="Announcement" variant="" spec={v["s0"]}></StackComponent>
    <StackText kind="p" variant="net-caption" spec={v["s1"]}>{"Fictional sample report · Captured "}{v["s2"]}</StackText>
    <StackComponent kind="Fold" variant="" spec={v["s3"]}>
        <StackText kind="p" variant="" spec={v["s4"]}>{v["strengths"]}</StackText></StackComponent>
    <StackComponent kind="Fold" variant="" spec={v["s5"]}>{v["findings"]}</StackComponent>
    <StackComponent kind="Fold" variant="" spec={v["s16"]}>{v["s17"]}</StackComponent>
    <StackComponent kind="Fold" variant="" spec={v["s18"]}>
        <StackText kind="p" variant="" spec={v["s19"]}>{v["questions"]}</StackText>
        <StackText kind="p" variant="net-muted" spec={v["s20"]}>{"Unread sections: education, skills, projects, certifications, Featured, and recommendations. Unread content is unknown, not missing. This text review does not assess photos, banners, or search ranking."}</StackText></StackComponent>
    <StackButton kind="button" variant="sheet-primary" spec={v["s21"]}>{v["s22"]}</StackButton>{v["s23"]}</StackFragment>
    );
}
