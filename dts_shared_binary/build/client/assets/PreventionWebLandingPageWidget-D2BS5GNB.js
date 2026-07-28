import{j as t}from"./jsx-runtime-BYsfuH3T.js";import{r as m}from"./chunk-JZWAC4HX-B9gBqAB-.js";function f({pageId:r,activeDomain:o,includeMetaTags:a=!1,includeCss:n=!1,langCode:d="en"}){const e=`pw-widget-${r}`,s=`
		.${e} {
			background: #ffffff;
			border: 1px solid #e2e8f0;
			border-radius: 10px;
			padding: 1rem;
			box-shadow: 0 1px 2px rgba(15, 23, 42, 0.04);
			font-family: var(--font-family, "Segoe UI", Tahoma, sans-serif);
			line-height: 1.65;
			color: #0f172a;
		}
		@media (min-width: 768px) {
			.${e} {
				padding: 1.25rem 1.5rem;
			}
		}
		.${e} .field--name-body {
			max-width: 100%;
		}
		.${e} h1,
		.${e} h2,
		.${e} h3,
		.${e} h4,
		.${e} h5,
		.${e} h6 {
			margin: 1.5rem 0 0.75rem;
			line-height: 1.25;
			font-weight: 700;
			color: #0f172a;
		}
		.${e} h1 { font-size: 2rem; }
		.${e} h2 { font-size: 1.5rem; }
		.${e} h3 { font-size: 1.25rem; }
		.${e} h2:first-child {
			margin-top: 0;
		}
		.${e} p {
			margin: 0 0 1rem;
		}
		.${e} ul,
		.${e} ol {
			margin: 0 0 1rem 1.5rem;
			padding: 0;
		}
		.${e} li {
			margin: 0.35rem 0;
		}
		.${e} a {
			color: #0ea5e9;
			text-decoration: underline;
			text-underline-offset: 2px;
		}
		.${e} a:hover {
			color: #0284c7;
		}
		.${e} img,
		.${e} iframe,
		.${e} video,
		.${e} table {
			max-width: 100%;
		}
		.${e} table {
			border-collapse: collapse;
			margin: 1rem 0;
		}
		.${e} th,
		.${e} td {
			border: 1px solid #cbd5e1;
			padding: 0.5rem 0.65rem;
			text-align: left;
		}
	`;return m.useEffect(()=>{const i=document.createElement("script");return i.id=r,i.src=`https://publish.preventionweb.net/widget.js?rand='${r}'`,i.type="text/javascript",i.crossOrigin="anonymous",i.onload=()=>{window.PW_Widget&&window.PW_Widget.initialize({contenttype:"landingpage",pageid:r,activedomain:o,includemetatags:a,includecss:n,langcode:d,suffixID:r})},document.body.appendChild(i),()=>{document.body.removeChild(i)}},[r,o,a,n,d]),t.jsxs(t.Fragment,{children:[!n&&t.jsx("style",{children:s}),t.jsx("div",{className:e,children:"Loading..."})]})}export{f as P};
