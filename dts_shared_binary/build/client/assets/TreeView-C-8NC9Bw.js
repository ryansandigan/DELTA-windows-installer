import{j as n}from"./jsx-runtime-BYsfuH3T.js";import{r as l}from"./chunk-JZWAC4HX-B9gBqAB-.js";import{L as be}from"./link-CWyQTN5h.js";const xe=f=>{const a=[`
            p.tree {
                margin-top: 2rem !important;
                margin-left: 4rem !important;
            }
			
			[dir="rtl"] p.tree {
 		   		margin-left: 0 !important;
    			margin-right: 4rem !important;
			}

            ul.tree {
                margin-left: 5rem !important;
                z-index: 1;
                position: none;
            }

            p.tree,
            ul.tree,
            ul.tree ul {
                position: none;
                list-style: none;
                margin: 0;
                padding: 0;
            }

            ul.tree ul {
                margin-left: 1.0em;
            }

            .tree-intro,
            ul.tree li {
                position: relative;
                
                margin-left: 0;
                padding-left: 3em;
                margin-top: 0;
                margin-bottom: 0;
                
                border-left: thin solid #000;

                color: #000;
            }

			[dir="rtl"] .tree-intro,
			[dir="rtl"] ul.tree li {
    			padding-left: 0;
    			padding-right: 3em;
    			border-left: none;
    			border-right: thin solid #000; /* flip border */
			}

            ul.tree li:last-child {
                border-left: none;
            }

            ul.tree li:before {
                position: absolute;
                top: 0;
                left: 0;

                width: 2.5em; /* width of horizontal line */
                height: 0.5em; /* vertical position of line */
                vertical-align: top;
                border-bottom: thin solid #000;
                content: "";
                display: inline-block;
            }

			[dir="rtl"] ul.tree li:before {
    			left: auto;
    			right: 0; /* move the line to the right */
    			border-bottom: thin solid #000; /* stays same */
			}

            ul.tree li:last-child:before {
                border-left: thin solid #000;
            }

            ul.tree li button {
                display: inline-block;
                background: none;
                cursor: pointer;
                margin-right: 5px;
                font-size: x-small;
            }

            ul.tree li button.btn-face {
                background-color: buttonface;
                padding: 4px 8px 1px 8px;
                border: 1px solid #000;
                border-radius: 5px;
            }

            .tree-btn {
                display: inline-block;
                background-color: buttonface;
                padding: 4px 8px 1px 8px;
                border: 1px solid #000;
                border-radius: 5px;
                margin-right: 1rem;
                white-space: nowrap;
                cursor: pointer;
            }
			[dir="rtl"] .tree-btn {
			    margin-right: 0;
    			margin-left: 1rem;
			}
            .tree-btn.main-btn {
                padding: 4px 8px 4px 8px;
            }
            .tree-dialog .mg-button.mg-button-primary {
                margin-right: 1rem;
            }

            .tree-search {  
                display: inline-block;
                padding: 0.4rem;
            }

            .btn-face.select {
                display: none;
                padding: 4px 8px 2px 8px !important;
                font-size: x-small;
                text-transform: uppercase;
                font-weight: bold;
                margin-left: 0.5rem;
            }
            ul.tree li div {
                position: relative;
                display: inline-block;
                color: #000;
            }
            ul.tree li div:hover .btn-face.select {
                display: inline-block;
            }

            .tree-dialog {
                max-width: 50vw;
                max-width: none !important;
                max-height: none !important;
            }
            .tree-dialog .dts-form__body {
                position: relative;
                overflow: scroll;
                // height: 500px;
                border-bottom: 1px dotted #979797 !important;
            }
            .tree-footer {
                display: flex;  /* Enables flexbox */
                justify-content: space-between; /* Puts text on the left & button on the right */
                align-items: center; /* Vertically align items */
                width: 100%;
                padding-top: 1.5rem;
            }
            .tree-footer div {
                font-weight: bold;
                flex: 1; /* Allows it to take up available space */
                white-space: normal; /* Allows text wrapping */
            }
            .tree-footer div .selected {
                display: inline-flex; align-items: center; background: rgb(240, 240, 240); color: rgb(51, 51, 51); border-radius: 4px; padding: 4px 8px; margin: 2px; border: 1px solid rgb(204, 204, 204);
            }
            .tree-checkbox {
                margin-right: 0.5rem;
            }
			[dir="rtl"] .tree-checkbox {
    			margin-right: 0;
    			margin-left: 0.5rem;
			}
            .tree-button-select {
                display: inline-block;
                background-color: buttonface;
                padding: 4px 8px 1px 8px;
                border: 1px solid #000;
                border-radius: 5px;
                white-space: nowrap;
            }

            .tree-btn {
                color: #000;
                text-decoration: none !important;
            }

            ${f}
        `],j="TreeView";if(!document.getElementById(j)){const g=document.createElement("style");g.type="text/css",g.id=j,g.innerHTML=a[0],document.head.appendChild(g)}},ke=l.forwardRef(({ctx:f=null,treeData:a=[],caption:j="",rootCaption:g="Root",base_path:ie="",onApply:L=null,onClose:V=null,onRenderItemName:$=null,multiSelect:v=!1,noSelect:F=!1,appendCss:oe="",disableButtonSelect:le=!1,dialogMode:E=!0,search:ae=!0,onItemClick:D=void 0,defaultSelectedIds:S=[],itemLink:T="",expandByDefault:R=!1,showActionFooter:B=null},de)=>{if(f==null)throw new Error("ViewContext is required");const c=l.useRef({}),[J,p]=l.useState({}),[b,z]=l.useState(""),[M,C]=l.useState(!1),[P,N]=l.useState(!0),[m,I]=l.useState(Object.fromEntries(S.map(e=>[e,!0])));l.useEffect(()=>{I(e=>{const t=Object.fromEntries(S.map(s=>[s,!0]));return JSON.stringify(e)!==JSON.stringify(t)?t:e})},[S]);const o=l.useRef(null);l.useEffect(()=>{xe(oe)},[]),l.useEffect(()=>{const e=a.flatMap(r=>G(r)),t=e.every(r=>c.current[r.id]),s=e.some(r=>c.current[r.id]);C(t),N(!s)},[a]),l.useEffect(()=>{if(b){C(!1),N(!1);const e={};A(a,b,e),p(t=>JSON.stringify(t)!==JSON.stringify(e)?e:t)}else p(e=>Object.keys(e).length?{}:e)},[b]);const ce=()=>{C(!0),N(!1),a.forEach(e=>_(e,c.current)),p({...c.current})},ue=()=>{N(!0),C(!1),c.current={},p({})},_=(e,t)=>{t[e.id]=!0,e.children?.forEach(s=>_(s,t))},me=(e,t)=>{e.preventDefault(),c.current[t]=!c.current[t],p({...c.current})};l.useEffect(()=>{const e=t=>{o.current&&t.target!==o.current&&(t.preventDefault(),o.current.focus())};return o.current&&o.current.addEventListener("focusin",e),()=>{o.current&&o.current.removeEventListener("focusin",e)}},[]);const[fe,pe]=l.useState(!1);l.useEffect(()=>{pe(document.dir==="rtl")},[]);const A=(e,t,s)=>t?e.map(r=>{const i=r.name.toLowerCase().includes(t.toLowerCase()),d=A(r.children,t,s)||[];return i||d.length>0?(s[r.id]=!0,{...r,children:d}):null}).filter(Boolean):e,G=e=>{const t=e.children||[];return[e,...t.flatMap(s=>G(s))]},K=(e,t="")=>{const s=t?`${t},${e.id}`:`${e.id}`;return{...e,dataIds:s,children:e.children.map(r=>K(r,s))}},Q=e=>{e.preventDefault();const t=e.target.closest("li").getAttribute("data-id")||"",s=e.target.closest("li").getAttribute("data-ids")||"",r=e.target.closest("li").querySelector("span")?.textContent||"",i=s.split(","),d=o.current;if(d){let ne=[],se=[];i.forEach(u=>{const w=d.querySelector(`li[data-id="${u}"] span`),h=d.querySelectorAll(`li[data-id="${u}"] textarea[data-id="${u}"]`);ne.push(w?.textContent||"");let k={};Array.from(h).forEach(y=>{k[y.name]=y.value}),se.push({id:u,...k})});const x=d.querySelector(".tree-footer div");if(x){x.setAttribute("selected-name",r),x.setAttribute("data-id",t);const u=document.createElement("div");u.classList.add("selected");const w=document.createElement("span");w.textContent=ne.join(" / ");const h=document.createElement("span");h.style.marginLeft="5px",h.style.cursor="pointer",h.style.color="red",h.textContent="×",h.addEventListener("click",()=>{const y=u.closest("div[selected-name]");u.remove(),y&&(y.setAttribute("data-id",""),y.setAttribute("data-ids",""))}),u.appendChild(w),u.appendChild(h),x.innerHTML="",x.appendChild(u),x.setAttribute("data-ids",s);const k=d.querySelector(".tree-hidden-data");k&&(k.value=JSON.stringify(se))}}},U=e=>{e.preventDefault(),I(t=>({...t,[e.target.closest("li").getAttribute("data-id")]:e.target.checked}))},W=e=>$?$(e):{},X=e=>{let t=T?T.replace("[id]",e.id):"";return n.jsx(n.Fragment,{children:t?n.jsx(be,{lang:f.lang,to:t,children:n.jsx("span",{children:e.name})}):n.jsx("span",{children:e.name})})},Y=(e,t="")=>n.jsx("ul",{className:"tree",children:e.map(s=>{const r=K(s,t);return n.jsx("li",{role:"presentation","data-id":r.id,"data-ids":r.ids,"data-path":r.path,"data-has_children":r.has_children,children:r.children.length>0?n.jsxs(n.Fragment,{children:[n.jsx("button",{className:"mg-button mg-button--small mg-button-system",onClick:i=>me(i,r.id),children:J[r.id]?"▼":fe?"◄":"►"})," ",v&&n.jsx("input",{className:"tree-checkbox",type:"checkbox",onChange:i=>U(i),checked:m[r.id]||!1}),n.jsxs("div",{...W(r),onClick:ee,children:[X(r),!v&&!F&&n.jsxs("button",{className:"btn-face select",onClick:i=>Q(i),children:[" ","Select"," "]})]}),Object.entries(r.hiddenData||{}).map(([i,d])=>n.jsx("textarea",{"data-id":r.id,name:i,defaultValue:d?JSON.stringify(d):"",style:{display:"none"}},`${r.id}-${i}`)),J[r.id]&&Y(r.children,r.dataIds)]}):n.jsxs(n.Fragment,{children:[v&&n.jsx("input",{className:"tree-checkbox",type:"checkbox",onChange:i=>U(i),checked:m[r.id]||!1}),n.jsxs("div",{...W(r),onClick:ee,children:[X(r),!v&&!F&&n.jsxs("button",{className:"btn-face select",onClick:i=>Q(i),children:[" ","Select"," "]})]}),Object.entries(r.hiddenData||{}).map(([i,d])=>n.jsx("textarea",{"data-id":r.id,name:i,defaultValue:d?JSON.stringify(d):"",style:{display:"none"}},`${r.id}-${i}`))]})},r.id)})}),O=()=>{p({}),z("");const e=o.current;if(e){const s=e.querySelector(".tree-footer div");s&&(s.textContent="",s.setAttribute("data-ids",""),s.setAttribute("data-id",""),s.setAttribute("selected-name",""));const r=e.querySelector(".tree-hidden-data");r&&(r.value="")}const t=e?.querySelector(".dts-form__body");t&&(t.style.height="")},Z=e=>{if(e&&e.preventDefault(),o.current){E&&o.current.showModal(),setTimeout(()=>{o.current?.focus()},10);let t=[];t[0]=o.current.querySelector(".dts-dialog__content")?.offsetHeight||0,t[1]=o.current.querySelector(".dts-dialog__header")?.offsetHeight||0,t[2]=o.current.querySelector(".tree-filters")?.offsetHeight||0,t[3]=o.current.querySelector(".tree-footer")?.offsetHeight||0;let s=t[0]-t[1]-t[2]-t[3]-16;const r=o.current.querySelector(".dts-form__body");r&&(r.style.height=`${window.innerHeight-s}px`)}},q=e=>{e&&e.preventDefault(),V&&V(),o.current&&typeof o.current.close=="function"&&o.current.close(),O()},he=e=>{if(e&&e.preventDefault(),o.current){const t=o.current.querySelector(".tree-footer div"),s=o.current.querySelector(".tree-hidden-data"),r=t.querySelector(".selected span"),i={dataIds:t.getAttribute("data-ids"),names:r?.textContent||"",selectedId:t.getAttribute("data-id")||"",selectedName:t.getAttribute("selected-name"),data:JSON.parse(s.value||"[]")};if(i.selectedId===""){alert("No item selected.");return}L&&L(i||{}),O(),E&&o.current.close()}},ee=e=>{e&&e.preventDefault(),!v&&typeof D=="function"&&D(e,o?.current||null)},ge=(e,t)=>{let s=[];const r=i=>{t.includes(i.id)&&s.push({id:i.id,name:i.name}),i.children?.length&&i.children.forEach(r)};return e.forEach(r),s};l.useImperativeHandle(de,()=>({treeViewOpen:Z,treeViewClose:q,treeViewClear:O,getCheckedItemIds:()=>Object.keys(m).filter(e=>m[e]),getCheckedItemNames:()=>{const e=Object.keys(m).filter(t=>m[t]);return ge(a,e)},clearCheckedItems:()=>I({})}));const te=b?A(a,b,{}):a,re=e=>n.jsxs("div",{children:[n.jsxs("div",{className:"dts-form__actions dts-form-component mg-grid mg-grid__col-6",children:[n.jsx("a",{className:"mg-button mg-button--small mg-button-system",role:"button",onClick:ce,style:{pointerEvents:M?"none":"auto",opacity:M?.5:1},children:f.t({code:"common.expand_all",msg:"Expand All"})}),n.jsx("a",{className:"mg-button mg-button--small mg-button-system",role:"button",onClick:ue,style:{pointerEvents:P?"none":"auto",opacity:P?.5:1},children:f.t({code:"common.collapse_all",msg:"Collapse All"})}),ae&&n.jsx("input",{id:"search-input",name:"search",type:"text",placeholder:f.t({code:"common.search_placeholder_dotdotdot",msg:"Search..."}),value:b,onChange:t=>z(t.target.value)})]}),n.jsxs("div",{className:"dts-form__body",children:[n.jsx("p",{className:"tree",style:{marginBottom:"1rem"},children:g}),te.length>0?Y(te):n.jsx("p",{className:"tree",children:f.t({code:"common.no_results_found",msg:"No results found"})})]}),e&&n.jsxs(n.Fragment,{children:[n.jsxs("div",{className:"tree-footer",children:[n.jsx("div",{}),n.jsx("button",{className:"mg-button mg-button-primary",onClick:he,children:"Apply"}),n.jsx("button",{className:"mg-button mg-button-outline",onClick:q,children:"Discard"})]}),n.jsx("textarea",{className:"tree-hidden-data",style:{display:"none"}})]})]}),H=(e,t)=>{for(const s of e){if(s.id===t)return s;if(s.children?.length){const r=H(s.children,t);if(r)return r}}return null};return l.useEffect(()=>{Object.keys(m).forEach(e=>{if(m[e]){let t=H(a,e);for(;t?.parentId;)c.current[t.parentId]=!0,t=H(a,t.parentId)}}),p({...c.current})},[m,a]),l.useEffect(()=>{if(R){const e={};a.forEach(t=>_(t,e)),c.current=e,p({...e})}},[R,a]),n.jsxs(n.Fragment,{children:[E?n.jsx("dialog",{ref:o,className:"dts-dialog tree-dialog",children:n.jsxs("div",{className:"dts-dialog__content",children:[n.jsxs("div",{className:"dts-dialog__header",style:{justifyContent:"space-between"},children:[n.jsx("h2",{className:"dts-heading-2",style:{marginBottom:"0px"},children:j}),n.jsx("a",{type:"button","aria-label":"Close dialog",onClick:q,className:"dts-dialog-close-button",children:n.jsx("svg",{"aria-hidden":"true",focusable:"false",role:"img",children:n.jsx("use",{href:`${ie}/assets/icons/close.svg#close`})})})]}),re(B||!0)]})}):n.jsx("div",{ref:o,children:re(B||!1)}),le?null:n.jsx("button",{className:"tree-button-select",onClick:Z,children:j})]})});export{ke as T};
