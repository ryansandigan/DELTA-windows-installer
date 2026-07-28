import{j as t}from"./jsx-runtime-BYsfuH3T.js";import{r as b,R as S,c as oe}from"./chunk-JZWAC4HX-B9gBqAB-.js";import{M as re}from"./container-CZi-9S8x.js";import{L as J}from"./link-CWyQTN5h.js";import{F as U,d as ae,e as le,b as ie}from"./form_components-BqVdIN1C.js";import{T as se}from"./toast.esm-S2Ggdnus.js";import{b as de,a as z,g as ce,c as ue}from"./date-Bm0m0Sa7.js";import{S as ge}from"./submit-DOcUJ4lB.js";import{C as Y,p as W,r as me,a as G}from"./index-C6yB1ywj.js";import{T as fe}from"./TreeView-C-8NC9Bw.js";function H(e){let a=[];{let s={defs:[]},c=!0;for(let i of e)i.uiRow?c=!1:i.uiRowNew&&(c=!0),(i.uiRow||c)&&(s.defs.length&&a.push(s),i.uiRow?s={uiRow:i.uiRow,uiRowDefFromKey:i.key,defs:[]}:s={defs:[]}),s.defs.push(i);s.defs.length&&a.push(s)}return a}function X(e,a,s){let c=e.defs.length,i="",d;if(c<3&&(c=3),e.defs.length==1){let o=e.defs[0];(o.key=="spatialFootprint"||o.key=="attachments")&&(c=1),o.type=="textarea"&&(c=2)}e.uiRow&&(e.uiRow.colOverride&&(c=e.uiRow.colOverride),e.uiRow.label&&(d=t.jsx("h3",{className:"row-header-"+e.uiRowDefFromKey,children:e.uiRow.label}))),i=`mg-grid mg-grid__col-${c}`;let r=!0;for(let o of e.defs)if(!o.repeatable)r=!1;else{let n=!0;for(let l of a)if(l.repeatable&&l.repeatable.group==o.repeatable.group&&l.repeatable.index==o.repeatable.index){let u=s[l.key];u!=null&&u!==""&&(n=!1)}n||(r=!1)}return{className:i,emptyRepeatables:r,header:d}}function ye(e){if(!e.def)throw new Error("no props.def");let a=e.def.label;return e.def.required&&(a+=" *"),t.jsx("div",{title:e.def.tooltip,className:"dts-form-component",children:t.jsxs(U,{label:a,children:[e.child,t.jsx(ae,{errors:e.errors}),e.def.description&&t.jsx("p",{children:e.def.description})]})})}function q(e){return t.jsx("div",{className:"dts-form-component",children:t.jsx(U,{label:e.label,children:e.child})})}let P=!1;function pe(e){let a=e.ctx;const s=b.useRef(null),c=d=>{s.current?.show({severity:"error",detail:d,life:5e3})};let i=function(d,r){let o={...e.def};return r&&(o.label=r),t.jsx(ye,{def:o,child:d,errors:e.errors})};switch(e.def.type){default:throw new Error(`Unknown type ${e.def.type} for field ${e.def.key}`);case"approval_status":{if(!e.user)throw new Error("userRole is required when using approvalStatus field");if(e.user.role=="data-collector"||e.user.role=="data-validator"||e.user.role=="admin"){let l=e.value;return i(t.jsxs(t.Fragment,{children:[t.jsx("input",{type:"text",defaultValue:e.enumData.find(u=>u.key==l).label,disabled:!0}),t.jsx("input",{type:"hidden",name:e.name,value:l})]}))}let n=e.value;return i(t.jsxs(t.Fragment,{children:[t.jsx("input",{type:"text",defaultValue:e.enumData.find(l=>l.key==n).label,disabled:!0}),e.disabled&&t.jsx("input",{type:"hidden",name:e.name,value:""})]}))}case"enum":{let n=e.value;return i(t.jsxs(t.Fragment,{children:[t.jsx("select",{required:e.def.required,name:e.name,defaultValue:n,onChange:e.onChange,disabled:e.disabled,children:e.enumData.map(l=>t.jsx("option",{value:l.key,children:l.label},l.key))}),e.disabled&&t.jsx("input",{type:"hidden",name:e.name,value:""})]}))}case"enum-flex":{let n=e.value,l=e.enumData.some(u=>u.key==n);return i(t.jsxs("select",{required:e.def.required,name:e.name,defaultValue:n,onChange:e.onChange,children:[!l&&n&&t.jsx("option",{value:n,children:n},n),e.enumData.map(u=>t.jsx("option",{value:u.key,children:u.label},u.key))]}))}case"bool":return e.value?i(t.jsxs(t.Fragment,{children:[t.jsx("input",{type:"hidden",name:e.name,value:"off"}),t.jsx("input",{type:"checkbox",name:e.name,defaultChecked:!0,onChange:e.onChange})]})):i(t.jsxs(t.Fragment,{children:[t.jsx("input",{type:"hidden",name:e.name,value:"off"}),t.jsx("input",{type:"checkbox",name:e.name,onChange:e.onChange})]}));case"textarea":{let n="";return e.value!==null&&e.value!==void 0&&(n=e.value),i(t.jsx("textarea",{required:e.def.required,name:e.name,defaultValue:n,onChange:e.onChange}))}case"json":{let n="";return e.value!==null&&e.value!==void 0&&(n=JSON.stringify(e.value)),i(t.jsx("textarea",{required:e.def.required,name:e.name,defaultValue:n,onChange:e.onChange}))}case"date_optional_precision":{let n=e.value||"",l="yyyy-mm-dd",u={y:0,m:0,d:0};n&&(n.length==10?u={y:Number(n.slice(0,4)),m:Number(n.slice(5,7)),d:Number(n.slice(8))}:n.length==7?(u={y:Number(n.slice(0,4)),m:Number(n.slice(5)),d:1},l="yyyy-mm"):n.length==4?(u={y:Number(n),m:1,d:1},l="yyyy"):P||(P=!0,c(`Invalid date format in database. Removing value for field ${e.def.label}. Got date: ${n}`)));let f=(h,v)=>v=="yyyy"?h.y?String(h.y):"":v=="yyyy-mm"?!h.y||!h.m?"":h.y+"-"+String(h.m).padStart(2,"0"):!h.y||!h.m||!h.d?"":h.y+"-"+String(h.m).padStart(2,"0")+"-"+String(h.d).padStart(2,"0"),[g,x]=b.useState(n),[m,p]=b.useState(u),[y,j]=b.useState(l),w=h=>{console.log("setting date in db format",h),x(h)};return t.jsxs("div",{children:[t.jsx(se,{ref:s,position:"top-center"}),t.jsx(q,{label:e.def.label+" "+a.t({code:"common.format",msg:"Format"}),child:t.jsxs("select",{value:y,onChange:h=>{let v=h.target.value;j(v),x(f(m,v)),e.onChange&&e.onChange(h)},children:[t.jsx("option",{value:"yyyy-mm-dd",children:a.t({code:"common.date_format_full_date",msg:"Full date"})}),t.jsx("option",{value:"yyyy-mm",children:a.t({code:"common.date_format_year_month",msg:"Year and month"})}),t.jsx("option",{value:"yyyy",children:a.t({code:"common.date_format_year_only",msg:"Year only"})})]})}),t.jsx("input",{type:"hidden",name:e.name,value:g}),y=="yyyy-mm-dd"&&i(t.jsx("input",{id:e.def.key,required:e.def.required,type:"date",value:m.y+"-"+String(m.m).padStart(2,"0")+"-"+String(m.d).padStart(2,"0"),onChange:h=>{let v=h.target.value,F={y:0,m:0,d:0};if(v.length>=10){let N=v.split("-");F={y:Number(N[0]),m:Number(N[1]),d:Number(N[2])}}p(F),w(f(F,y)),e.onChange&&e.onChange(h)}}),e.def.label+" "+a.t({code:"common.date",msg:"Date"})),y=="yyyy-mm"&&t.jsxs(t.Fragment,{children:[i(t.jsx("input",{id:e.def.key,required:e.def.required,type:"text",inputMode:"numeric",defaultValue:m.y||"",onBlur:h=>{let v=h.target.value;if(!/^\d{4}$/.test(v)){c(a.t({code:"common.invalid_year_format",msg:"Invalid year format, must be YYYY."}));return}let F={y:Number(v),m:m.m,d:0};p(F),w(f(F,y)),e.onChange&&e.onChange(h)}}),e.def.label+" "+a.t({code:"common.year",msg:"Year"})),t.jsx(q,{label:e.def.label+" "+a.t({code:"common.month",msg:"Month"}),child:t.jsxs("select",{value:m.m||"",onChange:h=>{let v={y:m.y,m:Number(h.target.value),d:0};p(v),w(f(v,y)),e.onChange&&e.onChange(h)},children:[t.jsx("option",{value:"",children:a.t({code:"common.select",msg:"Select"})},""),Array.from({length:12},(h,v)=>t.jsx("option",{value:v+1,children:ce(a,v+1)},v))]})})]}),y=="yyyy"&&t.jsx(t.Fragment,{children:i(t.jsx("input",{id:e.def.key,required:e.def.required,type:"text",inputMode:"numeric",defaultValue:m.y||"",onBlur:h=>{let v=h.target.value;if(!/^\d{4}$/.test(v)){c(a.t({code:"common.invalid_year_format",msg:"Invalid year format, must be YYYY."}));return}let F={y:Number(v),m:m.m,d:0};p(F),w(f(F,y)),e.onChange&&e.onChange(h)}}),e.def.label+" "+a.t({code:"common.year",msg:"Year"}))})]})}case"text":case"date":case"datetime":case"number":case"money":case"uuid":let r="";if(e.value!==null&&e.value!==void 0)switch(e.def.type){case"text":{r=e.value;break}case"date":{let n=e.value;r=z(n);break}case"datetime":{let n=e.value;r=de(n);break}case"number":{let n=e.value;r=String(n);break}case"money":{r=e.value;break}default:throw new Error("unknown type: "+e.def.type)}let o="";switch(e.def.type){case"text":case"date":o=e.def.type;break;case"datetime":o="datetime-local";break;case"number":return i(t.jsx("input",{required:e.def.required,type:"text",inputMode:"numeric",pattern:"[0-9]*",name:e.name,defaultValue:r,onChange:e.onChange}));case"money":return i(t.jsx("input",{required:e.def.required,type:"text",inputMode:"decimal",pattern:"[0-9]*\\.?[0-9]*",name:e.name,defaultValue:r,onChange:e.onChange}))}if(o=="")throw new Error("inputType is empty");return i(t.jsx("input",{required:e.def.required,type:o,name:e.name,defaultValue:r,onChange:e.onChange}));case"temp_hidden":{let n=e.value;return i(t.jsx(t.Fragment,{children:t.jsx("input",{type:"hidden",id:e.name,required:e.def.required,name:e.name,defaultValue:n})}))}}}function he(e){const a=e.ctx;if(!e.def)throw new Error("props.def not passed to form/Inputs");if(!Array.isArray(e.def))throw new Error("props.def must be an array");let s=e.def;return s=s.filter(i=>i.key!="legacyData"),H(s).map((i,d)=>{let r=X(i,s,e.fields),o=null,n=[];return t.jsxs(S.Fragment,{children:[r.header,t.jsx("div",{className:r.className,children:i.defs.map((l,u)=>{if(l.repeatable){let x=s.findIndex(j=>j.key==l.key),m=!1,p=l.repeatable.group,y=l.repeatable.index;if(x<s.length-1){let j=s[x+1];j.repeatable&&(j.repeatable.group!=p||j.repeatable.index!=y)&&(m=!0)}if(m){let j="repeatable-add-"+p+"-"+y;n.push(t.jsx("button",{className:j,children:a.t({code:"common.add",msg:"Add"})},j))}}let f=null;if(e.elementsAfter&&e.elementsAfter[l.key]&&(u==i.defs.length-1?o=e.elementsAfter[l.key]:f=e.elementsAfter[l.key]),e.override&&e.override[l.key]!==void 0)return t.jsxs(S.Fragment,{children:[e.override[l.key],f]},l.key);let g;return e.errors&&e.errors.fields&&(g=le(e.errors.fields[l.key])),t.jsx(S.Fragment,{children:l.key==="approvalStatus"&&e.id==null?null:t.jsxs(t.Fragment,{children:[t.jsx(pe,{ctx:a,user:e.user,def:l,name:l.key,value:e.fields[l.key],errors:g,enumData:l.enumData},l.key),f]})},l.key)})},`div-${d}-random`),n,o]},d)})}function K(e,a,s){let i=e.querySelector("[name="+a+"]").closest(".dts-form-component");s?i.style.display="grid":i.style.display="none";let d=e.querySelector(".row-header-"+a);d&&(s?d.style.display="inline":d.style.display="none")}function R(e,a,s){let c=".repeatable-add-"+a+"-"+s;return e.querySelector(c)}function be(e){if(!e.inputsRef||!e.inputsRef.current)return;let a=e.inputsRef.current,s=new Map;for(let i of e.defs){if(!i.repeatable)continue;let d=i.repeatable.group,r=i.repeatable.index,n=a.querySelector("[name="+i.key+"]").value,l=s.get(d)||new Set;n!==""&&l.add(r),s.set(d,l)}let c=new Map;for(let i of e.defs){if(!i.repeatable)continue;let d=i.repeatable.group,r=i.repeatable.index,o=c.get(d);(!o||r>o)&&c.set(d,r)}for(let[i,d]of s.entries()){let r=0;d.size&&(r=Math.max(...d));for(let o of e.defs){if(!o.repeatable||i!=o.repeatable.group)continue;let n=o.repeatable.index,l=n<=r;K(a,o.key,l);let u=R(a,i,n);if(u&&(u.style.display="none"),n==0)continue;let f=R(a,i,n-1);if(!f)continue;let g=c.get(i);r==n-1&&n!=g+1&&(f.style.display="block"),f.addEventListener("click",x=>{x.preventDefault(),f.style.display="none";for(let m of e.defs){if(!m.repeatable)continue;let p=m.repeatable.group,y=m.repeatable.index;p==i&&y==n&&K(a,m.key,!0)}if(n!=g){let m=R(a,i,n);m&&(m.style.display="block")}})}}}function Ze(e){if(!e.fieldsDef)throw new Error("props.fieldsDef not passed to FormView");if(!Array.isArray(e.fieldsDef))throw console.log("props.fieldsDef",e.fieldsDef),new Error("props.fieldsDef must be an array");let a=e.ctx;const s=e.title;let c=b.useRef(null);const i=oe(),d=i.state==="submitting"||i.state==="loading";let[r,o]=b.useState(0);return b.useEffect(()=>{const n=document.querySelector(".dts-form"),l=document.querySelector("#form-default-submit-button");let u={inputsRef:c,defs:e.fieldsDef};be(u);const f=()=>{l&&(l.setAttribute("disabled","true"),setTimeout(()=>{l.removeAttribute("disabled"),r++,o(r)},2e3))};return()=>{n&&n.removeEventListener("submit",f)}},[r,d]),t.jsx(re,{title:s,children:t.jsxs(t.Fragment,{children:[t.jsxs("section",{className:"dts-page-section",children:[t.jsx("p",{children:t.jsx(J,{lang:a.lang,to:e.listUrl||e.path,children:s})}),e.edit&&e.id&&t.jsx("p",{children:t.jsx(J,{lang:a.lang,to:e.viewUrl||`${e.path}/${e.id}`,children:a.t({code:"common.view",msg:"View"})})}),t.jsx("h2",{children:e.edit?e.editLabel:e.addLabel}),e.edit&&e.id&&t.jsxs("p",{children:[a.t({code:"common.id",msg:"ID"}),": ",String(e.id)]}),e.infoNodes]}),t.jsxs(ie,{ctx:e.ctx,formRef:e.formRef,errors:e.errors,className:"dts-form",id:e.id?`${e.id}`:"form-new",children:[e.hiddenFields,t.jsx("div",{ref:c,children:t.jsx(he,{ctx:a,user:e.user,def:e.fieldsDef,fields:e.fields,errors:e.errors,override:e.override,elementsAfter:e.elementsAfter,id:e.id},e.id)}),t.jsx("div",{className:"dts-form__actions",children:e.overrideSubmitMainForm?e.overrideSubmitMainForm:t.jsx(t.Fragment,{children:t.jsx(ge,{id:"form-default-submit-button",disabled:d,label:a.t({code:"common.save",msg:"Save"})})})})]})]})})}const ve=e=>typeof e=="boolean"||e instanceof Boolean,xe=e=>typeof e=="number"||e instanceof Number,je=e=>typeof e=="bigint"||e instanceof BigInt,Z=e=>!!e&&e instanceof Date,ke=e=>typeof e=="string"||e instanceof String,we=e=>Array.isArray(e),Q=e=>typeof e=="object"&&e!==null,ee=e=>!!e&&e instanceof Object&&typeof e=="function";function D(e,a){return a===void 0&&(a=!1),!e||a?`"${e}"`:e}function _e(e,a,s){return s?JSON.stringify(e):a?`"${e}"`:e}function te(e){let{field:a,value:s,data:c,lastElement:i,openBracket:d,closeBracket:r,level:o,style:n,shouldExpandNode:l,clickToExpandNode:u,outerRef:f,beforeExpandChange:g}=e;const x=b.useRef(!1),[m,p]=b.useState(()=>l(o,s,a)),y=b.useRef(null);b.useEffect(()=>{x.current?p(l(o,s,a)):x.current=!0},[l]);const j=b.useId();if(c.length===0)return Fe({field:a,openBracket:d,closeBracket:r,lastElement:i,style:n});const w=m?n.collapseIcon:n.expandIcon,h=m?n.ariaLables.collapseJson:n.ariaLables.expandJson,v=o+1,F=c.length-1,N=k=>{m!==k&&(!g||g({level:o,value:s,field:a,newExpandValue:k}))&&p(k)},I=k=>{if(k.key==="ArrowRight"||k.key==="ArrowLeft")k.preventDefault(),N(k.key==="ArrowRight");else if(k.key==="ArrowUp"||k.key==="ArrowDown"){k.preventDefault();const E=k.key==="ArrowUp"?-1:1;if(!f.current)return;const C=f.current.querySelectorAll("[role=button]");let L=-1;for(let A=0;A<C.length;A++)if(C[A].tabIndex===0){L=A;break}if(L<0)return;const M=(L+E+C.length)%C.length;C[L].tabIndex=-1,C[M].tabIndex=0,C[M].focus()}},B=()=>{var k;N(!m);const E=y.current;if(!E)return;const C=(k=f.current)===null||k===void 0?void 0:k.querySelector('[role=button][tabindex="0"]');C&&(C.tabIndex=-1),E.tabIndex=0,E.focus()};return b.createElement("div",{className:n.basicChildStyle,role:"treeitem","aria-expanded":m,"aria-selected":void 0},b.createElement("span",{className:w,onClick:B,onKeyDown:I,role:"button","aria-label":h,"aria-expanded":m,"aria-controls":m?j:void 0,ref:y,tabIndex:o===0?0:-1}),(a||a==="")&&(u?b.createElement("span",{className:n.clickableLabel,onClick:B,onKeyDown:I},D(a,n.quotesForFieldNames),":"):b.createElement("span",{className:n.label},D(a,n.quotesForFieldNames),":")),b.createElement("span",{className:n.punctuation},d),m?b.createElement("ul",{id:j,role:"group",className:n.childFieldsContainer},c.map((k,E)=>b.createElement(V,{key:k[0]||E,field:k[0],value:k[1],style:n,lastElement:E===F,level:v,shouldExpandNode:l,clickToExpandNode:u,beforeExpandChange:g,outerRef:f}))):b.createElement("span",{className:n.collapsedContent,onClick:B,onKeyDown:I}),b.createElement("span",{className:n.punctuation},r),!i&&b.createElement("span",{className:n.punctuation},","))}function Fe(e){let{field:a,openBracket:s,closeBracket:c,lastElement:i,style:d}=e;return b.createElement("div",{className:d.basicChildStyle,role:"treeitem","aria-selected":void 0},(a||a==="")&&b.createElement("span",{className:d.label},D(a,d.quotesForFieldNames),":"),b.createElement("span",{className:d.punctuation},s),b.createElement("span",{className:d.punctuation},c),!i&&b.createElement("span",{className:d.punctuation},","))}function Ce(e){let{field:a,value:s,style:c,lastElement:i,shouldExpandNode:d,clickToExpandNode:r,level:o,outerRef:n,beforeExpandChange:l}=e;return te({field:a,value:s,lastElement:i||!1,level:o,openBracket:"{",closeBracket:"}",style:c,shouldExpandNode:d,clickToExpandNode:r,data:Object.keys(s).map(u=>[u,s[u]]),outerRef:n,beforeExpandChange:l})}function Ee(e){let{field:a,value:s,style:c,lastElement:i,level:d,shouldExpandNode:r,clickToExpandNode:o,outerRef:n,beforeExpandChange:l}=e;return te({field:a,value:s,lastElement:i||!1,level:d,openBracket:"[",closeBracket:"]",style:c,shouldExpandNode:r,clickToExpandNode:o,data:s.map(u=>[void 0,u]),outerRef:n,beforeExpandChange:l})}function Se(e){let{field:a,value:s,style:c,lastElement:i}=e,d,r=c.otherValue;return s===null?(d="null",r=c.nullValue):s===void 0?(d="undefined",r=c.undefinedValue):ke(s)?(d=_e(s,!c.noQuotesForStringValues,c.stringifyStringValues),r=c.stringValue):ve(s)?(d=s?"true":"false",r=c.booleanValue):xe(s)?(d=s.toString(),r=c.numberValue):je(s)?(d=`${s.toString()}n`,r=c.numberValue):Z(s)?d=s.toISOString():ee(s)?d="function() { }":d=s.toString(),b.createElement("div",{className:c.basicChildStyle,role:"treeitem","aria-selected":void 0},(a||a==="")&&b.createElement("span",{className:c.label},D(a,c.quotesForFieldNames),":"),b.createElement("span",{className:r},d),!i&&b.createElement("span",{className:c.punctuation},","))}function V(e){const a=e.value;return we(a)?b.createElement(Ee,Object.assign({},e)):Q(a)&&!Z(a)&&!ee(a)?b.createElement(Ce,Object.assign({},e)):b.createElement(Se,Object.assign({},e))}var _={"container-light":"_2IvMF _GzYRV","basic-element-style":"_2bkNM","child-fields-container":"_1BXBN","label-light":"_1MGIk","clickable-label-light":"_2YKJg _1MGIk _1MFti","punctuation-light":"_3uHL6 _3eOF8","value-null-light":"_2T6PJ","value-undefined-light":"_1Gho6","value-string-light":"_vGjyY","value-number-light":"_1bQdo","value-boolean-light":"_3zQKs","value-other-light":"_1xvuR","collapse-icon-light":"_oLqym _f10Tu _1MFti _1LId0","expand-icon-light":"_2AXVT _f10Tu _1MFti _1UmXx","collapsed-content-light":"_2KJWg _1pNG9 _1MFti"};const Ne={collapseJson:"collapse JSON",expandJson:"expand JSON"},T={container:_["container-light"],basicChildStyle:_["basic-element-style"],childFieldsContainer:_["child-fields-container"],label:_["label-light"],clickableLabel:_["clickable-label-light"],nullValue:_["value-null-light"],undefinedValue:_["value-undefined-light"],stringValue:_["value-string-light"],booleanValue:_["value-boolean-light"],numberValue:_["value-number-light"],otherValue:_["value-other-light"],punctuation:_["punctuation-light"],collapseIcon:_["collapse-icon-light"],expandIcon:_["expand-icon-light"],collapsedContent:_["collapsed-content-light"],noQuotesForStringValues:!1,quotesForFieldNames:!1,ariaLables:Ne,stringifyStringValues:!1},ne=()=>!0,Le=e=>{let{data:a,style:s=T,shouldExpandNode:c=ne,clickToExpandNode:i=!1,beforeExpandChange:d,compactTopLevel:r,...o}=e;const n=b.useRef(null);return b.createElement("div",Object.assign({"aria-label":"JSON view"},o,{className:s.container,ref:n,role:"tree"}),r&&Q(a)?Object.entries(a).map(l=>{let[u,f]=l;return b.createElement(V,{key:u,field:u,value:f,style:{...T,...s},lastElement:!0,level:1,shouldExpandNode:c,clickToExpandNode:i,beforeExpandChange:d,outerRef:n})}):b.createElement(V,{value:a,style:{...T,...s},lastElement:!0,level:0,shouldExpandNode:c,clickToExpandNode:i,outerRef:n,beforeExpandChange:d}))};function Qe(e){if(!e.def)throw new Error("props.def not passed to view");let a=e.def;return e.user?.role!="admin"&&(a=a.filter(c=>c.key!="legacyData")),H(a).map((c,i)=>{let d=X(c,a,e.fields),r=null;return t.jsxs(S.Fragment,{children:[!d.emptyRepeatables&&d.header,t.jsx("div",{className:d.className,children:c.defs.map((o,n)=>{let l=null;if(e.elementsAfter&&e.elementsAfter[o.key]&&(n==c.defs.length-1?r=e.elementsAfter[o.key]:l=e.elementsAfter[o.key]),e.override&&e.override[o.key]!==void 0)return t.jsxs(S.Fragment,{children:[e.override[o.key],l]},o.key);if(o.repeatable){let u=!0;for(let f of a)if(f.repeatable&&f.repeatable.group==o.repeatable.group&&f.repeatable.index==o.repeatable.index){let g=e.fields[f.key];g!=null&&g!==""&&(u=!1)}if(u)return t.jsx(S.Fragment,{children:l},o.key)}return t.jsxs(S.Fragment,{children:[t.jsx(Ae,{def:o,value:e.fields[o.key]},o.key),l]},o.key)})}),r]},i)})}function Ae(e){const[a,s]=b.useState(!1);if(b.useEffect(()=>{s(!0)},[]),e.def.type==="temp_hidden")return"";if(e.value===null||e.value===void 0)return t.jsxs("p",{children:[e.def.label,": -"]});switch(e.def.type){default:throw new Error(`Unknown type ${e.def.type} for field ${e.def.key}`);case"bool":let c=e.value;return t.jsxs("p",{children:[e.def.label,": ",String(c)]});case"number":let i=e.value;return t.jsxs("p",{children:[e.def.label,": ",String(i)]});case"uuid":case"textarea":case"text":case"money":case"date_optional_precision":if(typeof e.value!="string")throw new Error(`invalid data for field ${e.def.key}, not a string, got: ${e.value}`);let d=e.value;return d.trim()?t.jsxs("p",{children:[e.def.label,": ",d]}):t.jsxs("p",{children:[e.def.label,": -"]});case"date":{let r=e.value;return t.jsxs("p",{children:[e.def.label,": ",z(r)]})}case"datetime":{let r=e.value;return t.jsxs("p",{children:[e.def.label,": ",ue(r)]})}case"approval_status":case"enum":case"enum-flex":{let r=e.value,o=e.def.enumData.find(n=>n.key===r);return o?t.jsxs("p",{children:[e.def.label,": ",o.label]}):t.jsxs("p",{children:[e.def.label,": ",r]})}case"json":{if(!a){let r=JSON.stringify(e.value);return t.jsxs(t.Fragment,{children:[t.jsx("p",{children:e.def.label}),t.jsx("pre",{children:r})]})}return t.jsxs(t.Fragment,{children:[t.jsx("p",{children:e.def.label}),t.jsx(Le,{data:e.value,shouldExpandNode:ne,style:T})]})}}}function et({ctx:e,divisions:a=[],ctryIso3:s="",treeData:c=[],initialData:i=[],geographicLevel:d=!0}){const r=b.useRef(null),o=b.useRef(null),n=b.useRef(null),l=g=>{g&&g.preventDefault(),r.current?.close(),o.current?.treeViewClear()},u=g=>{g.preventDefault(),r.current?.showModal();const x=[r.current?.querySelector(".dts-dialog__content")?.offsetHeight||0,r.current?.querySelector(".dts-dialog__header")?.offsetHeight||0,r.current?.querySelector(".tree-filters")?.offsetHeight||0,r.current?.querySelector(".tree-footer")?.offsetHeight||0],m=x[0]-x[1]-x[2]-100,p=r.current?.querySelector(".dts-form__body");p&&(p.style.height=`${m-(window.innerHeight-m)}px`)},f=(()=>{try{return Array.isArray(i)?i:typeof i=="string"?JSON.parse(i)||[]:[]}catch{return[]}})();return t.jsxs(t.Fragment,{children:[t.jsx(Y,{ctx:e,divisions:a,ctryIso3:s,caption:e.t({code:"record.spatial_footprint",msg:"Spatial footprint"}),ref:n,id:"spatialFootprint",mapper_preview:!0,table_columns:[{type:"dialog_field",dialog_field_id:"title",caption:e.t({code:"common.title",msg:"Title"}),width:"40%"},{type:"custom",caption:e.t({code:"common.option",msg:"Option"}),render:g=>g.map_option==="Map coordinates"?t.jsx(t.Fragment,{children:t.jsx("span",{children:e.t({code:"spatial_footprint.map_coordinates",msg:"Map coordinates"})})}):g.map_option==="Geographic level"?t.jsx(t.Fragment,{children:t.jsx("span",{children:e.t({code:"spatial_footprint.geographic_level",msg:"Geographic level"})})}):null,width:"40%"},{type:"action",caption:e.t({code:"common.action",msg:"Action"}),width:"20%"}],dialog_fields:[{id:"title",caption:e.t({code:"common.title",msg:"Title"}),type:"input",required:!0},{id:"map_option",caption:e.t({code:"spatial_footprint.item_type",msg:"Item type"}),type:"option",options:[{value:"Map coordinates",label:e.t({code:"geographies.map_coordinates",msg:"Map coordinates"})},{value:"Geographic level",label:e.t({code:"geographies.geographic_level",msg:"Geographic level"})}],onChange:g=>{const x=g.target.value,m=document.getElementById("spatialFootprint_map_coords"),p=document.getElementById("spatialFootprint_geographic_level"),y=m.closest(".dts-form-component"),j=p.closest(".dts-form-component");x==="Map coordinates"?(y.style.setProperty("display","block"),j.style.setProperty("display","none")):x==="Geographic level"&&(y.style.setProperty("display","none"),j.style.setProperty("display","block"))},show:d},{id:"map_coords",caption:e.t({code:"spatial_footprint.map_coordinates",msg:"Map coordinates"}),type:"mapper",placeholder:"",mapperGeoJSONField:"geojson"},{id:"geographic_level",caption:e.t({code:"spatial_footprint.geographic_level",msg:"Geographic level"}),type:"custom",render:(g,x,m)=>t.jsx(t.Fragment,{children:t.jsxs("div",{className:"input-group",children:[t.jsxs("div",{id:"spatialFootprint_geographic_level_container",className:"wrapper",children:[t.jsx("span",{onClick:()=>{W(m.geojson)},children:g}),t.jsxs("a",{href:"#",className:"btn",onClick:u,children:[t.jsx("img",{src:"/assets/icons/globe.svg",alt:"Globe SVG File",title:"Globe SVG File"}),e.t({code:"common.select",msg:"Select"})]})]}),t.jsx("textarea",{id:"spatialFootprint_geographic_level",name:"spatialFootprint_geographic_level",className:"dts-hidden-textarea",style:{display:"none"}})]})})},{id:"geojson",caption:e.t({code:"common.map_coordinates_geographic_level",msg:"Map coordinates / Geographic level"}),type:"hidden",required:!0}],data:f,onChange:g=>{try{Array.isArray(g)}catch{console.error("Failed to process items.")}}}),t.jsx("dialog",{ref:r,className:"dts-dialog tree-dialog",children:t.jsxs("div",{className:"dts-dialog__content",children:[t.jsxs("div",{className:"dts-dialog__header",style:{justifyContent:"space-between"},children:[t.jsx("h2",{className:"dts-heading-2",style:{marginBottom:"0px"},children:e.t({code:"spatial_footprint.select_geographic_level",msg:"Select geographic level"})}),t.jsx("a",{type:"button","aria-label":e.t({code:"common.close_dialog",msg:"Close dialog"}),onClick:l,className:"dts-dialog-close-button",children:t.jsx("svg",{"aria-hidden":"true",focusable:"false",role:"img",className:"dts-svg-24",children:t.jsx("use",{href:"/assets/icons/close.svg#close"})})})]}),t.jsx(fe,{ctx:e,dialogMode:!1,ref:o,treeData:c??[],caption:e.t({code:"spatial_footprint.select_geographic_level",msg:"Select geographic level"}),rootCaption:e.t({code:"spatial_footprint.geographic_levels",msg:"Geographic levels"}),onApply:async g=>{n.current.getDialogRef()&&(n.current.getDialogRef().querySelector("#spatialFootprint_geographic_level_container span").textContent=g.names,await Promise.all(g.data.map(async x=>{if(x.id==g.selectedId)try{const m=await fetch(`/${e.lang}/api/geojson/${x.id}`);if(!m.ok)throw new Error("Failed to fetch GeoJSON");const{geojson:p}=await m.json();let y={type:"Feature",geometry:p,properties:{division_id:g.selectedId||null,division_ids:g.dataIds?g.dataIds.split(","):[],import_id:x?.importId?JSON.parse(x.importId):null,level:x?.level?JSON.parse(x.level):null,name:x?.name?JSON.parse(x.name):null,national_id:x?.nationalId?JSON.parse(x.nationalId):null}};y=me(y),n.current.getDialogRef().querySelector("#spatialFootprint_geographic_level").value=JSON.stringify(y);const j={id:"geojson",value:y};n.current.handleFieldChange(j,y);const w={id:"geographic_level",value:g.names};n.current.handleFieldChange(w,g.names)}catch(m){console.error("Error fetching GEoJSON",m)}})),l())},onClose:()=>{l()},appendCss:`
                            ul.tree li div[disable="true"] {
                                color: #ccc;
                            }
                            ul.tree li div[disable="true"] .btn-face.select {
                                display: none;
                            }
                        `,disableButtonSelect:!0,showActionFooter:!0})]})})]})}const $e="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js",Oe="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css",$={polygon:"#0074D9",line:"#FF851B",rectangle:"#2ECC40",circle:"#FF4136"},Te={iconUrl:"https://maps.google.com/mapfiles/ms/icons/red-dot.png",iconSize:[20,20],iconAnchor:[5,20],popupAnchor:[0,-20],shadowUrl:null,className:"custom-leaflet-marker"},De=({ctx:e,dataSource:a=[],filterCaption:s=""})=>{const c=d=>{const r=window.open("","_blank");if(!r){alert("Popup blocker is preventing the map from opening.");return}r.document.write(`
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <title>Map preview</title>
            <link rel="stylesheet" href="${Oe}" />
            <script src="${$e}"><\/script>
            <style>
              body { font-family: Arial, sans-serif; }
              #map { position: relative; width: 100%; height: 100vh; }
    
              /* Floating Legend Styling */
              #legend {
                position: absolute;
                bottom: 20px;
                right: 20px;
                background-color: rgba(200, 200, 200, 0.9);
                padding: 10px;
                border-radius: 5px;
                box-shadow: 0px 0px 5px rgba(0,0,0,0.3);
                font-size: 14px;
                z-index: 1000;
              }
              #legend h4 {
                margin: 0 0 8px;
                font-weight: bold;
                text-align: center;
                border-bottom: 1px solid #555;
                padding-bottom: 5px;
              }
              .legend-item {
                display: flex;
                align-items: center;
                margin-bottom: 5px;
              }
              .legend-item input { margin-right: 8px; }
            </style>
          </head>
          <body>
            <div id="map"></div>
            <div id="legend">
              <h4>${s}</h4>
              <div class="legend-item">
                <input type="checkbox" id="toggleDisaster" checked />
                <label for="toggleDisaster">Disaster Record</label>
              </div>
              <div class="legend-item">
                <input type="checkbox" id="toggleDamages" checked />
                <label for="toggleDamages">Damages</label>
              </div>
              <div class="legend-item">
                <input type="checkbox" id="toggleLosses" checked />
                <label for="toggleLosses">Losses</label>
              </div>
              <div class="legend-item">
                <input type="checkbox" id="toggleDisruptions" checked />
                <label for="toggleDisruptions">Disruptions</label>
              </div>
            </div>
    
            <script>
                const adjustZoomBasedOnDistance = (map, layerGroups) => {
                    const boundsArray = [];
    
                    layerGroups.forEach(group => {
                        if (map.hasLayer(group) && group.getLayers().length > 0) {
                            group.eachLayer(layer => {
                                if (layer.getBounds && layer.getBounds().isValid()) {
                                    boundsArray.push(layer.getBounds());
                                } else if (layer.getLatLng) {
                                    boundsArray.push(L.latLngBounds([layer.getLatLng()]));
                                }
                            });
                        }
                    });
    
                    if (boundsArray.length > 0) {
                        const bounds = L.latLngBounds(boundsArray.flat());
    
                        if (bounds.isValid()) {
                            const corners = bounds.getNorthEast().distanceTo(bounds.getSouthWest());
    
                            if (corners < 5000) {  
                                map.setView(bounds.getCenter(), 10); // Prevent over-zooming
                            } else {
                                map.fitBounds(bounds, { padding: [50, 50] });
                            }
                        }
                    } else {
                        console.warn("No valid bounds to fit the map.");
                        //map.setView([11.3233, 124.9200], 6);  // Default view if no layers are visible
                    }
                };
    
              window.onload = () => {
                const map = L.map("map"); //.setView([11.3233, 124.9200], 6);
                L.tileLayer("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png", {
                  attribution: "",
                }).addTo(map);
    
                const items = JSON.parse(\`${d}\`);
                
                // ✅ Layer Groups
                const layers = {
                  disaster: L.layerGroup().addTo(map),
                  damages: L.layerGroup().addTo(map),
                  losses: L.layerGroup().addTo(map),
                  disruptions: L.layerGroup().addTo(map),
                };
    
                // ✅ Define Colors for Each Type
                const getColorForType = (type) => ({
                  disaster: "${$.polygon}",
                  damages: "${$.circle}",
                  losses: "${$.rectangle}",
                  disruptions: "${$.line}",
                }[type] || "black");
    
                // ✅ Populate Layers
                items.forEach((item) => {
                  try {
                    console.log('item.type:', item.type);
                    console.log('getColorForType:', getColorForType(item.type));
                    const type = item.type;
                    const geojsonLayer = L.geoJSON(item.geojson, {
                      style: () => ({
                        color: getColorForType(type),
                        fillColor: getColorForType(type),
                        weight: 2,
                      }),
                      pointToLayer: (feature, latlng) => {
                        if (feature.geometry.type === "Point") {
                          const marker = L.marker(latlng, {
                            icon: L.icon(${JSON.stringify(Te)}),
                          });

                          // Bind popup only for markers
                          if (feature?.properties?.description) {
                            marker.bindPopup(feature.properties.description);
                          }

                          return marker;
                        }
                        return L.circleMarker(latlng, {
                          radius: 5,
                          color: getColorForType(type),
                          fillColor: getColorForType(type),
                          weight: 1,
                          opacity: 1,
                          fillOpacity: 0.8
                        });
                      }
                    });
    
                    layers[type]?.addLayer(geojsonLayer);
                  } catch (error) {
                    console.error("Error parsing GeoJSON:", error);
                  }
                });
    
                // ✅ Initial Zoom Adjustment
                setTimeout(() => adjustZoomBasedOnDistance(map, Object.values(layers)), 500);
    
                // ✅ Checkbox Event Listeners (Trigger Zoom Adjustment)
                const toggleLayer = (id, layer) => {
                  document.getElementById(id).addEventListener("change", (e) => {
                    if (e.target.checked) {
                      map.addLayer(layer);
                    } else {
                      map.removeLayer(layer);
                    }
                    adjustZoomBasedOnDistance(map, Object.values(layers));
                  });
                };
    
                toggleLayer("toggleDisaster", layers.disaster);
                toggleLayer("toggleDamages", layers.damages);
                toggleLayer("toggleLosses", layers.losses);
                toggleLayer("toggleDisruptions", layers.disruptions);

                setTimeout(() => {
                  // Remove attribution links
                  const attributionElement = document.querySelector(".leaflet-control-attribution.leaflet-control a");
                  if (attributionElement) {
                    attributionElement.remove();
                  }
                }, 50);
              };
            <\/script>
          </body>
          </html>
        `),r.document.close()},i=()=>{const d=[...(a[0]?.disaster_spatial_footprint||[]).map(r=>({id:r.id,title:r.title,geojson:r.geojson,map_coords:r.map_coords||{},type:"disaster"})),...[...a[0]?.disruptions?.map(r=>({...r,type:"disruptions"}))||[],...a[0]?.losses?.map(r=>({...r,type:"losses"}))||[],...a[0]?.damages?.map(r=>({...r,type:"damages"}))||[]].flatMap(r=>r.spatial_footprint.map(o=>({id:o.id,title:o.title,geojson:o.geojson,map_coords:o.map_coords||{},type:r.type})))].filter(r=>r.geojson);console.log("spatialData:",d),c(JSON.stringify(d))};return t.jsx("button",{onClick:i,style:{padding:"10px 16px",border:"1px solid rgb(221, 221, 221)",backgroundColor:"rgb(244, 244, 244)",color:"rgb(51, 51, 51)",fontSize:"14px",fontWeight:"normal",borderRadius:"4px",marginBottom:"2rem",cursor:"pointer"},children:e.t({code:"spatial_footprint.map_preview",msg:"Map preview"})})},Ie="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js",Be="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css",O={line:"#FF851B",rectangle:"#2ECC40",circle:"#FF4136",geographic_level:"#fc9003"},Re={iconUrl:"https://maps.google.com/mapfiles/ms/icons/red-dot.png",iconSize:[20,20],iconAnchor:[5,20],popupAnchor:[0,-20],shadowUrl:null,className:"custom-leaflet-marker"},Ve=({dataSource:e=[],filterCaption:a="",ctryIso3:s=""})=>{const c=async()=>{const r=s,o=`https://data.undrr.org/api/json/gis/countries/1.0.0/?cca3=${r}`,n=[43.833,87.616];try{if(!r)throw new Error("Country ISO3 code is missing");const l=await fetch(o);if(!l.ok)throw new Error(`Failed to fetch country data: ${l.statusText}`);const u=await l.json();if(!u?.data?.length)throw new Error(`Country API returned no data for ${r}`);const f=u.data[0]?.cca2;if(!f)throw new Error(`Country code not found for ${r}`);const g=`https://nominatim.openstreetmap.org/search?country=${f}&format=json&limit=1&polygon_geojson=1`,x=await fetch(g);if(!x.ok)throw new Error(`Failed to fetch Nominatim data: ${x.statusText}`);let m;try{if(m=await x.json(),!Array.isArray(m)||m.length===0)throw new Error(`Nominatim returned an empty result for ${f}`)}catch(w){throw new Error(`Failed to parse Nominatim JSON: ${w}`)}const{lat:p,lon:y,boundingbox:j}=m[0];return{coords:[parseFloat(p),parseFloat(y)],bounds:[[parseFloat(j[0]),parseFloat(j[2])],[parseFloat(j[1]),parseFloat(j[3])]]}}catch(l){return console.error("Error fetching country/location data:",l),{coords:n}}},i=async(r,o,n,l=[],u="")=>{const f=window.open("","_blank");if(!f){alert("Popup blocker is preventing the map from opening.");return}const{coords:g}=await c(),x=JSON.stringify(g);f.document.write(`
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <title>Map preview</title>
        <link rel="stylesheet" href="${Be}" />
        <script src="${Ie}"><\/script>
        <style>
            body { font-family: Arial, sans-serif; }

            #map { 
                width: 100%; 
                height: 100vh; 
            }

            #legend {
                position: absolute;
                bottom: 20px;
                right: 20px;
                background-color: rgba(255, 255, 255, 0.9);
                padding: 10px;
                border-radius: 5px;
                font-size: 13px;
                z-index: 1000;
                width: 250px;  /* Fixed width */
                height: 300px;  /* Fixed height for the entire container */
                overflow: hidden; /* Prevent container from growing */
            }

            #legend h4 {
                margin: 0;
                padding: 0;
                font-size: 16px;
                font-weight: bold;
                cursor: move; /* Show move cursor */
                background-color: rgba(255, 255, 255, 0.9);
            }

            #legend .legend-body {
                overflow-y: auto;  /* Allow scrolling */
                height: 250px;  /* Fixed height for the body section */
                padding-top: 10px;
            }

            .legend-item { 
                margin-bottom: 5px; 
            }

            .legend-subitem {
                margin-left: 20px;
                font-style: italic;
            }

            input[type="checkbox"] {
                margin-right: 5px;
            }
        </style>
      </head>
      <body>
        <div id="map"></div>
        <div id="legend">
            <h4 id="legend-header">${a||"Map Layers"}</h4>
            <div class="legend-body">
                <div class="legend-item">
                <input type="checkbox" id="layer-event" ${n.includes("event")?"checked":""} />
                <label for="layer-event">Disaster event - ${u}</label>
                </div>
                ${o.length>0?'<div for="layer-record" style="margin-top: 0.5rem; padding-left: 0.2rem">Disaster records</div>':""}
                ${o.map(m=>`
                    <div class="legend-item">
                        <input type="checkbox" id="layer-${m.id}" ${n.includes(m.id)?"checked":""} />
                        <label for="layer-${m.id}">${m.id.slice(0,8)}</label>
                        ${["damages","losses","disruptions"].map(p=>`
                            <div class="legend-subitem">
                            <input type="checkbox" id="layer-${m.id}-${p}" />
                            <label for="layer-${m.id}-${p}">${p}</label>
                            </div>`).join("")}
                    </div>`).join("")}
            </div>
        </div>

        <script>
            const hasValidGeometry = (g) =>
            g?.type === "Feature" && g.geometry && Object.keys(g.geometry).length ||
            g?.type === "FeatureCollection" && g.features?.some((f) => f.geometry && Object.keys(f.geometry).length);


          const adjustZoomBasedOnDistance = (map, layerGroups) => {
            const boundsArray = [];

            console.log('layerGroups:',layerGroups);

            layerGroups.forEach(group => {
              if (map.hasLayer(group) && group.getLayers().length > 0) {
                group.eachLayer(layer => {
                  if (layer.getBounds && layer.getBounds().isValid()) {
                    boundsArray.push(layer.getBounds());
                  } else if (layer.getLatLng) {
                    boundsArray.push(L.latLngBounds([layer.getLatLng()]));
                  }
                });
              }
            });

            if (boundsArray.length > 0) { 
              const bounds = L.latLngBounds(boundsArray.flat());
              if (bounds.isValid()) {
                const dist = bounds.getNorthEast().distanceTo(bounds.getSouthWest());
                if (dist < 5000) {
                  map.setView(bounds.getCenter(), 10);
                } else {
                  map.fitBounds(bounds, { padding: [50, 50] });
                }
              }
            } else {
                map.setView(${x}, 6); 
            }
          };

          window.onload = () => {
            const map = L.map("map");
            L.tileLayer("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png", { attribution: "" }).addTo(map);

            const items = ${JSON.stringify(r)};
            const defaultKeys = ${JSON.stringify(n)};
            const missing = ${JSON.stringify(l)};
            const layers = {};

            const getColor = (type) => ({
              event: "${O.geographic_level}",
              damages: "${O.circle}",
              losses: "${O.rectangle}",
              disruptions: "${O.line}",
            }[type] || "black");

            const renderGeoJson = (geojson, type) => {
                return L.geoJSON(geojson, {
                    style: function (feature) {
                        // Check if the GeoJSON is for division (you can check by a property or type)
                        const isDivisionLayer = feature?.properties?.division_id;  // Assuming division_id indicates division layers

                        // If it's a division layer, apply gray and dotted style
                        if (isDivisionLayer) {
                            return {
                            color: "gray",    // Set color to gray
                            weight: 1,        // Line weight (thickness)
                            // dashArray: "2,2",  // Dotted line (5px dash, 5px gap)
                            fillColor: 'gray', // optional
                            fillOpacity: 0.1       // make the inside transparent
                            };
                        }

                        // Otherwise, use the default style for other layers
                        const gType = feature?.geometry?.type;
                        return gType !== "Point" ? { color: getColor(type), weight: 2 } : undefined;
                    },
                    pointToLayer: function (feature, latlng) {
                        const marker = L.marker(latlng, {
                            icon: L.icon(${JSON.stringify(Re)})
                        });

                        // Bind popup only for markers with a description
                        if (feature?.properties?.description) {
                            marker.bindPopup(feature.properties.description);
                        }

                        return marker;
                    }
                });
            };

            //console.log('items:',items);

            items.forEach((item) => {
            const key = item.type === "event"
                ? "event"
                : item.type === "footprint"
                ? item.record_id
                : \`\${item.record_id}-\${item.type}\`;

                console.log('key:',key);

            if (hasValidGeometry(item.geojson)) {
                const geojson = renderGeoJson(item.geojson, item.type);

                if (!layers[key]) { 
                    layers[key] = L.layerGroup();
                }

                layers[key].addLayer(geojson);

                if (defaultKeys.includes(key)) {
                    layers[key].addTo(map);
                }
            } else {
                console.warn("❌ Invalid geometry skipped for key:", key, item.geojson);
            }
            });

            const keyOf = function(item) {
            return item.type === "event" ? "event" : item.record_id + "-" + item.type;
            };

            const lazyLoadMissingGeometries = () => {
            console.log("🔍 Lazy loading missing geometries:", missing);

            missing.forEach((item) => {
                const { type, record_id, geojson, division_id } = item;

                const key =
                type === "event"
                    ? "event"
                    : type === "footprint"
                    ? record_id
                    : \`\${record_id}-\${type}\`;

                console.log("📦 Fetching geometry for key:", key);

                fetch("/api/spatial-footprint-geojson?division_id=" + division_id + "&record_id=" + record_id)
                .then((res) => res.json())
                .then((geo) => {
                    if (!geo || !geo.geometry) {
                    console.warn("⚠️ Geometry missing or empty for key:", key, geo);
                    return;
                    }

                    geojson.geometry = geo.geometry;

                    const layer = renderGeoJson(geojson, type);

                    if (!layers[key]) layers[key] = L.layerGroup();
                    layers[key].addLayer(layer);

                    console.log("✅ Lazy-loaded layer added to key:", key, "Current keys:", Object.keys(layers));

                    const checkbox = document.getElementById("layer-" + key);
                    if (checkbox && checkbox.checked) {
                    console.log("⏪ Dispatching existing onchange for:", key);
                    checkbox.dispatchEvent(new Event("change"));
                    }

                })
                .catch((err) => {
                    console.error("❌ Fetch failed for", division_id, err);
                });
            });
            };


            document.getElementById("layer-event").onchange = function () {
                const key = "event";
                if (layers[key]) {
                    map[this.checked ? "addLayer" : "removeLayer"](layers[key]);
                }
            };

            ${o.map(m=>`
                  (() => {
                    const base = "${m.id}";
              
                    // Disaster record's main footprint layer toggle
                    const groupCb = document.getElementById("layer-" + base);
                    if (!groupCb) {
                      console.warn("Missing group checkbox for:", base);
                      return;
                    }
              
                    groupCb.onchange = () => {
                        const groupKey = base; // main footprint layer key
                        const isChecked = groupCb.checked;

                        console.log("Group toggled:", groupKey, "Checked:", isChecked);

                        // Toggle the group's own main footprint layer
                        if (layers[groupKey]) {
                            map[isChecked ? "addLayer" : "removeLayer"](layers[groupKey]);
                        } else {
                            console.warn("Main footprint layer not found for:", groupKey);
                        }

                        // Toggle sublayers: damages, losses, disruptions
                        ["damages", "losses", "disruptions"].forEach((sub) => {
                            const subKey = \`\${groupKey}-\${sub}\`;
                            const subCb = document.getElementById("layer-" + subKey);

                            if (subCb) {
                            subCb.checked = isChecked;

                            if (layers[subKey]) {
                                map[isChecked ? "addLayer" : "removeLayer"](layers[subKey]);
                            } else {
                                console.log("🕐 Waiting for lazy-loaded layer:", subKey);
                                const interval = setInterval(() => {
                                if (layers[subKey]) {
                                    console.log("✅ Lazy-loaded layer now ready. Applying toggle:", subKey);
                                    map[isChecked ? "addLayer" : "removeLayer"](layers[subKey]);
                                    clearInterval(interval);
                                }
                                }, 50); // retry every 50ms
                            }
                            } else {
                            console.warn("⚠️ Sublayer checkbox not found for:", subKey);
                            }
                        });

                        adjustZoomBasedOnDistance(map, Object.values(layers));
                    };
              
                    // Individual sublayers
                    ["damages", "losses", "disruptions"].forEach((sub) => {
                      const key = \`\${base}-\${sub}\`;
                      const cb = document.getElementById("layer-" + key);
              
                      if (!cb) {
                        console.warn("Missing checkbox for sublayer:", key);
                        return;
                      }
              
                      cb.onchange = () => {
                        console.log("Sublayer toggled:", key, "Checked:", cb.checked);
                        if (layers[key]) {
                          map[cb.checked ? "addLayer" : "removeLayer"](layers[key]);
                        } else {
                          console.warn("Layer not found for:", key);
                        }
                      };
                    });
                  })();`).join("")}              

            setTimeout(() => {
                console.log('layers after setTimeout:',layers);
                adjustZoomBasedOnDistance(map, Object.values(layers));
                lazyLoadMissingGeometries();

                setTimeout(() => {
                  // Remove attribution links
                  const attributionElement = document.querySelector(".leaflet-control-attribution.leaflet-control a");
                  if (attributionElement) {
                    attributionElement.remove();
                  }
                }, 50);
            }, 300);
          };

            const makeLegendDraggable = () => {
                // Correct the reference for the legend container
                const legend = document.getElementById("legend");  // Use this directly
                const legendHeader = document.getElementById("legend-header");  // Correct header ID

                if (!legend || !legendHeader) return;

                let offsetX = 0, offsetY = 0, isDragging = false;

                legendHeader.style.cursor = "move";  // Show the move cursor for dragging

                // Track the initial mouse position when drag starts
                legendHeader.onmousedown = (e) => {
                    isDragging = true;
                    offsetX = e.clientX - legend.getBoundingClientRect().left;
                    offsetY = e.clientY - legend.getBoundingClientRect().top;

                    document.onmousemove = (e) => {
                        if (!isDragging) return;

                        // Calculate the new position of the legend
                        let newLeft = e.clientX - offsetX;
                        let newTop = e.clientY - offsetY;

                        // **Prevent dragging out of viewport** (ensure it's within the window)
                        const maxLeft = window.innerWidth - legend.offsetWidth;
                        const maxTop = window.innerHeight - legend.offsetHeight;

                        newLeft = Math.max(0, Math.min(newLeft, maxLeft));
                        newTop = Math.max(0, Math.min(newTop, maxTop));

                        // Apply the new position
                        legend.style.left = \`\${newLeft}px\`;
                        legend.style.top = \`\${newTop}px\`;
                    };

                    document.onmouseup = () => {
                        isDragging = false;
                        document.onmousemove = null;
                        document.onmouseup = null;
                    };
                };
            };

            makeLegendDraggable();
        <\/script>
      </body>
      </html>
    `),f.document.close()},d=r=>{r.preventDefault();const o={event:[],records:[]},n=[];let l=null;const u=[],f=[],g=p=>p?.type==="Feature"&&p.geometry&&Object.keys(p.geometry).length||p?.type==="FeatureCollection"&&p.features?.some(y=>y.geometry&&Object.keys(y.geometry).length);console.log("dataSource:",e),e.length>0&&(l=e[0]?.id.slice(0,8)),e.forEach(p=>{p.event_spatial_footprint?.forEach(y=>{y.geojson&&(g(y.geojson)?o.event.push(y.geojson):f.push({type:"event",geojson:y.geojson,division_id:y.geojson.properties?.division_id}))}),p.disaster_records?.forEach(y=>{const j=y.id,w={id:j,footprint:[],damages:[],losses:[],disruptions:[]};y.spatial_footprint?.forEach(h=>{h.geojson&&(g(h.geojson)?w.footprint.push(h.geojson):f.push({type:"footprint",record_id:j,geojson:h.geojson,division_id:h.geojson.properties?.division_id}))}),y.damages?.forEach(h=>h.spatial_footprint?.forEach(v=>{v.geojson&&(g(v.geojson)?w.damages.push(v.geojson):f.push({type:"damages",record_id:j,geojson:v.geojson,division_id:v.geojson.properties?.division_id}))})),y.losses?.forEach(h=>h.spatial_footprint?.forEach(v=>{v.geojson&&(g(v.geojson)?w.losses.push(v.geojson):f.push({type:"losses",record_id:j,geojson:v.geojson,division_id:v.geojson.properties?.division_id}))})),y.disruption?.forEach(h=>h.spatial_footprint?.forEach(v=>{v.geojson&&(g(v.geojson)?w.disruptions.push(v.geojson):f.push({type:"disruptions",record_id:j,geojson:v.geojson,division_id:v.geojson.properties?.division_id}))})),o.records.push(w),n.push({id:j})})});const x=[...o.event.map(p=>({type:"event",geojson:p})),...o.records.flatMap(p=>[...p.footprint.map(y=>({type:"footprint",record_id:p.id,geojson:y})),...p.damages.map(y=>({type:"damages",record_id:p.id,geojson:y})),...p.losses.map(y=>({type:"losses",record_id:p.id,geojson:y})),...p.disruptions.map(y=>({type:"disruptions",record_id:p.id,geojson:y}))])];if(o.event.length)u.push("event");else{const p=o.records.find(y=>y.footprint.length>0);p&&u.push(p.id)}const m=Me(n);console.log("eventId:",l),i(x,m,u,f,l||"")};return t.jsx("button",{onClick:d,style:{padding:"10px 16px",border:"1px solid rgb(221, 221, 221)",backgroundColor:"rgb(244, 244, 244)",color:"rgb(51, 51, 51)",fontSize:"14px",fontWeight:"normal",borderRadius:"4px",marginBottom:"2rem",cursor:"pointer"},children:"Map preview"})};function Me(e){return Array.isArray(e)&&e.length===1&&e[0]?.id===null?[]:e}function tt({ctx:e,initialData:a=[],mapViewerOption:s=0,mapViewerDataSources:c=[],ctryIso3:i=""}){if(a){const d=r=>{r.preventDefault(),G(JSON.stringify(a))};return t.jsx(t.Fragment,{children:t.jsxs("div",{children:[t.jsxs("p",{children:[e.t({code:"record.spatial_footprint",msg:"Spatial footprint"}),":"]}),(()=>{try{let r=[];if(a){if(Array.isArray(a))r=a;else if(typeof a=="string")try{const o=JSON.parse(a);r=Array.isArray(o)?o:[]}catch(o){console.error("Invalid JSON in spatialFootprint:",o),r=[]}else console.warn("Unexpected type for spatialFootprint:",typeof a),r=[];if(r.length===0)return t.jsx(t.Fragment,{})}return t.jsxs(t.Fragment,{children:[t.jsxs("table",{style:{borderCollapse:"collapse",width:"100%",border:"1px solid #ddd",marginBottom:"2rem"},children:[t.jsx("thead",{children:t.jsxs("tr",{style:{backgroundColor:"#f4f4f4"},children:[t.jsx("th",{style:{border:"1px solid #ddd",padding:"8px",textAlign:"left",fontWeight:"normal"},children:e.t({code:"common.title",msg:"Title"})}),t.jsx("th",{style:{border:"1px solid #ddd",padding:"8px",textAlign:"left",fontWeight:"normal"},children:e.t({code:"common.option",msg:"Option"})})]})}),t.jsx("tbody",{children:r.map((o,n)=>{try{const l=o.map_option||"Unknown Option";return t.jsxs("tr",{children:[t.jsx("td",{style:{border:"1px solid #ddd",padding:"8px"},children:t.jsx("a",{href:"#",onClick:u=>{u.preventDefault();const f=[{geojson:o.geojson}];G(JSON.stringify(f))},children:o.title})}),t.jsx("td",{style:{border:"1px solid #ddd",padding:"8px"},children:t.jsx("a",{href:"#",onClick:u=>{u.preventDefault();const f=o.geojson;W(JSON.stringify(f))},children:l})})]},o.id||n)}catch{return t.jsxs("tr",{children:[t.jsx("td",{style:{border:"1px solid #ddd",padding:"8px"},children:o.title}),t.jsx("td",{style:{border:"1px solid #ddd",padding:"8px",color:"red"},children:"Invalid Data"})]},n)}})})]}),s===1&&t.jsx(De,{ctx:e,dataSource:c,filterCaption:e.t({code:"record.spatial_footprint",msg:"Spatial footprint"})}),s===0&&t.jsx("button",{onClick:d,style:{padding:"10px 16px",border:"1px solid #ddd",backgroundColor:"#f4f4f4",color:"#333",fontSize:"14px",fontWeight:"normal",borderRadius:"4px",marginBottom:"2rem",cursor:"pointer"},children:e.t({code:"record.spatial_footprint.map_preview",msg:"Map preview"})}),s===2&&t.jsx(Ve,{dataSource:c,filterCaption:e.t({code:"record.spatial_footprint",msg:"Spatial footprint"}),ctryIso3:i})]})}catch(r){return console.error("Error processing spatialFootprint:",r),t.jsx("p",{children:"Error loading spatialFootprint data."})}})()]})})}else return t.jsx(t.Fragment,{})}function nt({ctx:e,initialData:a,save_path_temp:s,file_viewer_temp_url:c,file_viewer_url:i,api_upload_url:d}){const r=(()=>{try{return Array.isArray(a)?a:typeof a=="string"?JSON.parse(a)||[]:[]}catch{return[]}})();return t.jsx(t.Fragment,{children:t.jsx(Y,{ctx:e,id:"attachments",caption:e.t({code:"common.attachments",msg:"Attachments"}),dnd_order:!0,save_path_temp:s,file_viewer_temp_url:c,file_viewer_url:i,api_upload_url:d,table_columns:[{type:"dialog_field",dialog_field_id:"title",caption:e.t({code:"common.title",msg:"Title"})},{type:"custom",caption:e.t({code:"common.tags",msg:"Tags"}),render:o=>{try{if(!o.tag)return"N/A";const n=o.tag;return Array.isArray(n)&&n.length>0?n.map(l=>l.name).join(", "):"N/A"}catch(n){return console.error("Failed to parse tags:",n),"N/A"}}},{type:"custom",caption:e.t({code:"attachments.file_or_url",msg:"File/URL"}),render:o=>{let n="N/A";const l=o?.file_option||"";if(l==="File"){const u=o.file?.name?o.file.name.split("/").pop():o.url,f=30;if(n=u,u&&u.length>f){const g=u.includes(".")?u.substring(u.lastIndexOf(".")):"";n=`${u.substring(0,f-g.length-3)}...${g}`}}else l==="Link"&&(n=o.url||"N/A");return n||"N/A"}},{type:"action",caption:e.t({code:"common.action",msg:"Action"})}],dialog_fields:[{id:"title",caption:e.t({code:"common.title",msg:"Title"}),type:"input"},{id:"tag",caption:e.t({code:"common.tags",msg:"Tags"}),type:"tokenfield",dataSource:e.url("/api/disaster-event/tags-sectors")},{id:"file_option",caption:e.t({code:"attachments.type",msg:"Type"}),type:"option",options:[{value:"File",label:e.t({code:"common.file",msg:"File"})},{value:"Link",label:e.t({code:"common.link",msg:"Link"})}],onChange:o=>{const n=o.target.value,l=document.getElementById("attachments_file"),u=document.getElementById("attachments_url");if(l&&u){const f=l.closest(".dts-form-component"),g=u.closest(".dts-form-component");n==="File"?(f?.style.setProperty("display","block"),g?.style.setProperty("display","none")):n==="Link"&&(f?.style.setProperty("display","none"),g?.style.setProperty("display","block"))}}},{id:"file",caption:e.t({code:"attachments.file_upload",msg:"File upload"}),type:"file"},{id:"url",caption:e.t({code:"attachments.link",msg:"Link"}),type:"input",placeholder:e.t({code:"attachments.enter_url",desc:"Placeholder for URL input field",msg:"Enter URL"})}],data:r,onChange:o=>{try{Array.isArray(o)}catch{console.error("Failed to process items.")}}})})}function ot({ctx:e,id:a="",initialData:s=[],file_viewer_url:c="",location:i="",countryAccountsId:d=""}){return s?t.jsxs(t.Fragment,{children:[t.jsxs("p",{children:[e.t({code:"attachments",msg:"Attachments"}),":"]}),(()=>{try{let r=[];if(Array.isArray(s))r=s;else if(typeof s=="string")try{const o=JSON.parse(s);r=Array.isArray(o)?o:[]}catch(o){console.error("Invalid JSON in attachments:",o),r=[]}else console.warn("Unexpected type for attachments:",typeof s),r=[];return r.length>0?t.jsxs("table",{style:{border:"1px solid #ddd",width:"100%",borderCollapse:"collapse",marginBottom:"2rem"},children:[t.jsx("thead",{children:t.jsxs("tr",{style:{backgroundColor:"#f2f2f2"},children:[t.jsx("th",{style:{border:"1px solid #ddd",padding:"8px",textAlign:"left",fontWeight:"normal"},children:"Title"}),t.jsx("th",{style:{border:"1px solid #ddd",padding:"8px",textAlign:"left",fontWeight:"normal"},children:"Tags"}),t.jsx("th",{style:{border:"1px solid #ddd",padding:"8px",textAlign:"left",fontWeight:"normal"},children:"File/URL"})]})}),t.jsx("tbody",{children:r.map(o=>{const n=o.tag?o.tag.map(u=>u.name).join(", "):"N/A";let l="N/A";if(o.file_option==="File"&&o.file){const u=o.file.name.split("/").pop(),f=i?`&loc=${i}`:"",g=c.includes("?")?"&":"?";l=t.jsx("a",{href:e.url(`${c}${g}name=${a}/${u}${f}`),target:"_blank",rel:"noopener noreferrer",children:u})}else o.file_option==="Link"&&(l=t.jsx("a",{href:o.url,target:"_blank",rel:"noopener noreferrer",children:o.url}));return t.jsxs("tr",{style:{borderBottom:"1px solid gray"},children:[t.jsx("td",{style:{border:"1px solid #ddd",padding:"8px"},children:o.title||"N/A"}),t.jsx("td",{style:{border:"1px solid #ddd",padding:"8px"},children:n}),t.jsx("td",{style:{border:"1px solid #ddd",padding:"8px"},children:l})]},o.id)})})]}):t.jsx(t.Fragment,{})}catch(r){return console.error("Error processing attachments:",r),t.jsx("p",{children:"Error loading attachments."})}})()]}):t.jsx(t.Fragment,{})}const Je="uploads",rt=`${Je}/temp`;export{ot as A,Qe as F,pe as I,tt as S,rt as T,ye as W,q as a,Ze as b,nt as c,et as d};
