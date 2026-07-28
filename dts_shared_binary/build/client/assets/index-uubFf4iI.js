import{j as e}from"./jsx-runtime-BYsfuH3T.js";import{r as a}from"./chunk-JZWAC4HX-B9gBqAB-.js";import{T as se}from"./TreeView-C-8NC9Bw.js";const re=c=>{const j=[`
            ${c}
        `],f="ContentPicker";if(!document.getElementById(f)){const l=document.createElement("style");l.type="text/css",l.id=f,l.innerHTML=j[0],document.head.appendChild(l)}},le=a.forwardRef(({ctx:c,id:j="",viewMode:f="grid",dataSources:l="",table_columns:d=[],caption:$="",defaultText:q="",appendCss:M="",base_path:Q="",displayName:z="",value:h="",required:U=!0,onSelect:N,multiSelect:u=!1,treeViewRootCaption:K="",disabledOnEdit:R=!1,selectAnyItem:T=!1},oe)=>{if(!c)throw new Error("ViewContext is required");const o=a.useRef(null),G=a.useRef(null),[b,C]=a.useState([]),[g,H]=a.useState(""),[L,J]=a.useState(g),[p,w]=a.useState(1),[I,A]=a.useState(1),v=10,[W,_]=a.useState(!1),[y,m]=a.useState(h),[F,x]=a.useState(""),k=a.useRef(null);a.useEffect(()=>{re(M)},[]),a.useEffect(()=>{m(h)},[h]);const E=async(t="",s=1)=>{if(_(!0),Array.isArray(l)){const n=(l??[]).filter(r=>(d??[]).some(i=>i.column_type==="db"&&i.searchable&&r[i.column_field]?.toString().toLowerCase().includes(t.toLowerCase())));A(Math.ceil(n.length/v)),C(n.slice((s-1)*v,s*v)),_(!1);return}if(!l){_(!1);return}if(f==="tree"){const n=await fetch(c.url(`${l}`));if(!n.ok)throw new Error("Failed to fetch data");const{data:r=[]}=await n.json();C(r),_(!1)}else try{const n=await fetch(c.url(`${l}?query=${t}&page=${s}&limit=${v}`));if(!n.ok)throw new Error("Failed to fetch data");const{data:r=[],totalRecords:i=0}=await n.json();A(Math.ceil(i/v)),C(r)}catch(n){console.error("Error fetching data:",n)}finally{_(!1)}};a.useEffect(()=>{const t=setTimeout(()=>{J(g)},500);return()=>{clearTimeout(t)}},[g]),a.useEffect(()=>{E(L,1)},[L]);const X=t=>{H(t.target.value),w(1)},Y=t=>{t&&t.preventDefault(),p<I&&(w(s=>s+1),E(g,p+1))},Z=t=>{t&&t.preventDefault(),p>1&&(w(s=>s-1),E(g,p-1))},O=t=>{if(t&&t.preventDefault(),o.current){o.current.showModal();let s=[];s[0]=o.current.querySelector(".dts-dialog__content")?.offsetHeight||0,s[1]=o.current.querySelector(".dts-dialog__header")?.offsetHeight||0;let n=s[0]-s[1];n+=240;const r=o.current.querySelector(".dts-form__body");if(r){r.style.height=`${window.innerHeight-n}px`;const i=o.current.querySelector(".cp-view-mode");i&&(i.style.display="block")}E()}},S=()=>{if(!o.current)return;const t=o.current.querySelector(".dts-form__body");t&&(t.style.height="auto",t.scrollTop=0);const s=o.current.querySelector(".cp-view-mode");s&&(s.style.display="none"),C([]),H(""),w(1),A(1)},B=t=>{t&&t.preventDefault(),o.current&&o.current.close(),S()},ee=t=>{t.preventDefault();const s=t.target.dataset.id,n=d.find(i=>i.is_primary_id)||d[0];if(!n){console.error("No primary column found in table_columns");return}const r=b.find(i=>i[n.column_field].toString()===s.toString());m(r._CpID),x(r._CpDisplayName),o.current&&o.current.close(),S(),typeof N=="function"&&N({value:r._CpID,name:r._CpDisplayName,object:r})},V=(t,s)=>{t.preventDefault(),u?(m(n=>{if(typeof n=="string"){const r=n.split(",").filter(i=>Number(i)!==s);return r.length?r.join(","):""}return n.filter(r=>r!==s)}),x(n=>Array.isArray(n)?n.filter(r=>r.id!==s):"")):(m(""),x(""))};a.useEffect(()=>{const t=n=>{n.key==="Escape"&&o.current?.open&&(o.current.close(),S())};document.addEventListener("keydown",t),h!==""&&(m(h),x(z));const s=n=>{const r=document.querySelector(`input[name="${j}"]`);if(r&&r.value.trim()===""){const i=r?.closest(".cp-input-container")||null;if(i){const P=i?.querySelector(".cp-unselected")||null;P&&P?.focus()}const D=r?.closest(".cp-input-container")?.querySelector(".cp-validation-popup")||null;if(D){D.style.display="block";const P=r.closest(".cp-input-container")?.clientHeight||0;D.style.bottom=`-${P+6}px`,setTimeout(()=>{D.style.display="none"},3e3)}n.preventDefault()}};if(U){const n=document.querySelector("form");n&&n.addEventListener("submit",s)}return()=>{document.removeEventListener("keydown",t)}},[]);const te=t=>{if(t.preventDefault(),k.current){const s=k.current.getCheckedItemIds(),n=k.current.getCheckedItemNames();k.current.clearCheckedItems(),o.current&&o.current.close(),m(s.length?s.join(","):""),x(n.length?n:[])}},ne=(t=[])=>!t||t.length===0?null:e.jsx(e.Fragment,{children:t.map(s=>e.jsxs("div",{className:"cp-selected","data-id":s.id,children:[e.jsx("span",{children:s.name}),e.jsx("span",{className:"cp-remove-item",onClick:n=>V(n,s.id),children:"×"})]},s.id))});return e.jsx(e.Fragment,{children:e.jsxs("div",{className:"content-picker",ref:G,children:[e.jsx("dialog",{ref:o,className:"dts-dialog",children:e.jsxs("div",{className:"dts-dialog__content",children:[e.jsxs("div",{className:"dts-dialog__header",style:{justifyContent:"space-between"},children:[e.jsx("h2",{className:"dts-heading-2",children:$}),e.jsx("a",{type:"button","aria-label":"Close dialog",onClick:B,className:"dts-dialog-close-button",children:e.jsx("svg",{"aria-hidden":"true",focusable:"false",role:"img",style:{cursor:"pointer"},children:e.jsx("use",{href:`${Q}/assets/icons/close.svg#close`})})})]}),f==="tree"&&e.jsx("div",{className:"cp-view-mode tree",style:{display:"none"},"data-value":h,children:e.jsx(se,{ctx:c,ref:k,treeData:b,rootCaption:K,dialogMode:!1,disableButtonSelect:!0,noSelect:!0,multiSelect:u,defaultSelectedIds:typeof y=="string"&&y!==""?y.split(","):[],appendCss:u?`
                                                .content-picker .cp-input-container {
                                                    position: relative;
                                                    display: flex;
                                                    flex-wrap: wrap;
                                                    align-items: stretch;
                                                    border: 1px solid #ccc;
                                                    border-radius: 0.25rem;
                                                    width: 100%;
                                                    background-color: #fff;
                                                    margin-top: 1rem;
                                                    margin-bottom: 2rem;
                                                    padding: 1.5px 2px 1.5px 1.5px;
                                                    gap: 1px;
                                                }

                                                .content-picker .cp-selected {
                                                    display: inline-flex;
                                                    align-items: center;
                                                    border-radius: 4px;
                                                    padding: 8px 12px;
                                                    border: 1px solid #E3E3E3;
                                                    font-size: 100%;
                                                    line-height: 1.15;
                                                    color: #495057;
                                                    background-color: #f8f9fa;
                                                    flex: 1 1 auto; /* Auto size unless multiple items */
                                                    max-width: calc(100% - 50px); /* Ensures it doesn't push the search icon */
                                                }

                                                .content-picker .cp-search {
                                                    display: flex;
                                                    align-items: center;
                                                    justify-content: center;
                                                    background-color: #f8f9fa;
                                                    border-radius: 4px;
                                                    border: 1px solid #E3E3E3;
                                                    padding: 0 10px;
                                                    height: auto;
                                                    min-height: 40px;
                                                    width: 40px;
                                                    margin-left: auto;
                                                    flex-shrink: 0; /* Ensures search stays at the right */
                                                }

                                                .content-picker .cp-search svg {
                                                    width: 20px;
                                                    height: 20px;
                                                }
                                            `:`
                                                ${T?`
                                                    ul.tree li span {
                                                        display: inline-block;
                                                        cursor: pointer;
                                                        padding: 0rem 0.3rem 0rem 0.3rem;
                                                        margin-bottom: 0.3rem;
                                                        background-color: #f9f9f9;
                                                        border: 1px solid #007B7A;
                                                        border-radius: 3px;
                                                    }
                                                    ul.tree li span:hover {
                                                        text-decoration: underline;
                                                    }
                                                `:`
                                                    ul.tree li[data-has_children="false"] span {
                                                        display: inline-block;
                                                        cursor: pointer;
                                                        padding: 0.3rem;
                                                        margin-bottom: 0.3rem;
                                                        background-color: #f9f9f9;
                                                        border: 1px solid #007B7A;
                                                        border-radius: 5px;
                                                    }
                                                    ul.tree li[data-has_children="false"]:hover span {
                                                        text-decoration: underline;
                                                    }
                                                `}

                                            `,onItemClick:t=>{if(!u){const s=()=>{const n=t.target.closest("li").getAttribute("data-id")||"",r=t.target.closest("li").getAttribute("data-path")||"";m(n),x(r),o.current&&o.current.close(),S(),typeof N=="function"&&N({value:n,name:r,object:t.target.closest("li")})};(T||(t.target.closest("li")?.getAttribute("data-has_children")||"")==="false")&&s()}}})}),f==="grid"&&e.jsxs("div",{className:"cp-view-mode grid",style:{display:"none"},children:[e.jsx("div",{className:"cp-filter dts-form-component",children:e.jsx("input",{type:"text",id:"content-picker-search",name:"content-picker-search",placeholder:c.t({code:"common.search_placeholder_dotdotdot",msg:"Search..."}),defaultValue:g,onChange:X})}),e.jsx("div",{className:"dts-form__body",children:e.jsx("div",{className:"cp-container",children:e.jsxs("table",{className:"dts-table",children:[e.jsx("thead",{children:e.jsx("tr",{children:(d??[]).map((t,s)=>e.jsx("th",{children:t.column_title},s))})}),e.jsx("tbody",{children:W?e.jsx("tr",{children:e.jsx("td",{colSpan:(d??[]).length,style:{textAlign:"center"},children:c.t({code:"common.loading_data_dotdotdot",msg:"Loading data..."})})}):b.length>0?b.map((t,s)=>{const n=d.find(r=>r.is_primary_id);return e.jsx("tr",{children:d.map((r,i)=>e.jsx("td",{children:r.column_type==="db"?t[r.column_field]||c.t({code:"common.not_available",msg:"N/A",desc:"Not available"}):e.jsx("a",{href:n?`#${t[n.column_field]}`:"#","data-id":n?`${t[n.column_field]}`:"",onClick:ee,children:c.t({code:"common.select",msg:"Select"})})},i))},s)}):e.jsx("tr",{children:e.jsx("td",{colSpan:(d??[]).length,style:{textAlign:"center"},children:c.t({code:"common.no_results_found",msg:"No results found"})})})})]})})}),e.jsxs("div",{className:"cp-footer",children:[e.jsxs("span",{children:[c.t({code:"common.page_current_of_total",msg:"Page {current} of {total}"},{current:p,total:I})," | ",c.t({code:"common.showing_n_items",msg:"Showing {n} items"},{n:(b??[]).length})]}),e.jsxs("div",{className:"cp-page-nav",children:[e.jsxs("button",{onClick:Z,disabled:p<=1,children:["◀"," ",c.t({code:"common.previous",msg:"Previous"})]}),e.jsxs("button",{onClick:Y,disabled:p>=I,children:[c.t({code:"common.next",msg:"Next"})," ","▶"]})]})]})]}),u&&e.jsxs("div",{className:"cp-action",children:[e.jsx("button",{className:"mg-button mg-button-primary",onClick:te,children:c.t({code:"common.apply_selection",msg:"Apply selection"})}),e.jsx("button",{className:"mg-button mg-button-outline",onClick:B,children:c.t({code:"common.discard",msg:"Discard"})})]})]})}),e.jsxs("div",{className:"cp-input-container",children:[y===""&&e.jsx("div",{className:"cp-unselected",tabIndex:0,children:e.jsx("span",{className:"cp-item-name",children:q!==""?q:$})}),y!==""&&!u&&e.jsxs("div",{className:"cp-selected",children:[e.jsx("span",{className:"cp-item-name",children:F}),!R&&e.jsx("span",{className:"cp-remove-item",onClick:t=>V(t),children:"×"})]}),u&&ne(F),!R&&e.jsx("div",{className:"cp-search",onClick:O,children:e.jsx("svg",{"aria-hidden":"true",focusable:"false",role:"img"})}),e.jsx("input",{type:"hidden",id:j,name:j,defaultValue:y}),e.jsxs("div",{className:"cp-validation-popup",children:["⚠️",c.t({code:"common.fill_out_this_field",msg:"Please fill out this field"})]})]})]})})});export{le as C};
