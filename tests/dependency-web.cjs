// Check the declarative React Router APIs in Jac's actual generated workspace.
// Run after jac build --as client workspace: node tests/dependency-web.cjs
const assert = require('node:assert/strict');
const {createRequire} = require('node:module');
const path = require('node:path');
const webRequire = createRequire(path.resolve(__dirname, '../.jac/client/configs/package.json'));
const React = webRequire('react');
const {renderToStaticMarkup} = webRequire('react-dom/server');
const {MemoryRouter, Routes, Route, Link, useNavigate, useLocation} = webRequire('react-router-dom');
function Screen() {
  assert.equal(typeof useNavigate(), 'function');
  return React.createElement(Link, {to: '/account'}, useLocation().pathname);
}
const html = renderToStaticMarkup(React.createElement(MemoryRouter, {initialEntries: ['/practice']},
  React.createElement(Routes, null,
    React.createElement(Route, {path: '/practice', element: React.createElement(Screen)}))));
assert.match(html, /href="\/account"/);
assert.match(html, />\/practice<\/a>/);
console.log('Jac web dependencies: declarative routing, location, navigation and links work.');
