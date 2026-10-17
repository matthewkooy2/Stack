"""Dependency-free, inert HTML table view of the editable resume records."""
from html import escape


def render_html(result):
    resume = result['resume']
    tables = []

    def table(title, rows):
        body = []
        for label, value in rows:
            if isinstance(value, list):
                rendered = '<ul>' + ''.join(f'<li>{escape(item)}</li>' for item in value) + '</ul>' if value else ''
            else:
                rendered = escape(value)
            body.append(f'<tr><th scope="row">{escape(label)}</th><td>{rendered or "<span class=empty>Not found</span>"}</td></tr>')
        tables.append(f'<table><caption>{escape(title)}</caption><tbody>{"".join(body)}</tbody></table>')

    profile = resume['profile']
    table('Profile', [(label, profile[key][1:] if key == 'links' else profile[key]) for label, key in
          [('Name', 'name'), ('Email', 'email'), ('Phone', 'phone'), ('Location', 'location'),
           ('Link', 'link'), ('Additional links', 'links'), ('Summary', 'summary')]
          if key != 'links' or len(profile['links']) > 1])
    groups = [
        ('education', 'Education', [('School', 'school'), ('Degree', 'degree'), ('GPA', 'gpa'),
                                    ('Date', 'date'), ('Location', 'location'), ('Descriptions', 'descriptions')]),
        ('workExperience', 'Work experience', [('Company', 'company'), ('Job title', 'jobTitle'),
                                              ('Date', 'date'), ('Location', 'location'), ('Descriptions', 'descriptions')]),
        ('projects', 'Project', [('Project', 'project'), ('Date', 'date'), ('Descriptions', 'descriptions')]),
    ]
    for key, title, fields in groups:
        for index, record in enumerate(resume[key], 1):
            table(f'{title} {index}', [(label, record[field]) for label, field in fields])
    table('Skills', [('Descriptions', resume['skills']['descriptions'])])
    if resume['unclassified']:
        table('Unclassified text', [('Text', resume['unclassified'])])
    warnings = ''.join(f'<li>{escape(item["code"])}</li>' for item in result['warnings'])
    return '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>Resume parser review</title><style>
body{font:15px/1.55 system-ui,sans-serif;color:#172338;background:#fff;margin:32px auto;max-width:900px;padding:0 20px}
h1{font-size:26px;margin-bottom:4px}p{color:#526079}table{border-collapse:collapse;width:100%;margin:24px 0;table-layout:fixed}
caption{text-align:left;font-weight:650;background:#eef2f7;padding:10px 14px;border:1px solid #d7dee8;border-bottom:0}
th,td{border:1px solid #d7dee8;padding:9px 12px;text-align:left;vertical-align:top;overflow-wrap:anywhere;white-space:pre-wrap}
th{width:145px;font-weight:550}ul{margin:0;padding-left:20px;white-space:normal}li{white-space:pre-wrap}.empty{color:#8a94a4;font-style:italic}
@media(max-width:560px){body{padding:0 10px;margin:16px auto}th{width:95px}th,td{padding:7px}}
@media print{body{font-size:11px}tr{break-inside:avoid}}
</style></head><body><h1>Resume parser review</h1>
<p>Independent parser · Review required. Missing fields are not inferred. Editable values and field-level source evidence are in the JSON output.</p>
''' + ''.join(tables) + (f'<p>Warnings</p><ul>{warnings}</ul>' if warnings else '') + '</body></html>\n'
