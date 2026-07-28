import{r as l}from"./chunk-JZWAC4HX-B9gBqAB-.js";import{u as te,P as ne,a as ae,b as oe,U as le,c as B,C as ie,h as U,O as H}from"./iconbase.esm-BPTj-nSg.js";import{C as se}from"./index.esm-CGeKxThE.js";function S(){return S=Object.assign?Object.assign.bind():function(e){for(var t=1;t<arguments.length;t++){var r=arguments[t];for(var a in r)({}).hasOwnProperty.call(r,a)&&(e[a]=r[a])}return e},S.apply(null,arguments)}function O(e){"@babel/helpers - typeof";return O=typeof Symbol=="function"&&typeof Symbol.iterator=="symbol"?function(t){return typeof t}:function(t){return t&&typeof Symbol=="function"&&t.constructor===Symbol&&t!==Symbol.prototype?"symbol":typeof t},O(e)}function ue(e,t){if(O(e)!="object"||!e)return e;var r=e[Symbol.toPrimitive];if(r!==void 0){var a=r.call(e,t);if(O(a)!="object")return a;throw new TypeError("@@toPrimitive must return a primitive value.")}return(t==="string"?String:Number)(e)}function ce(e){var t=ue(e,"string");return O(t)=="symbol"?t:t+""}function me(e,t,r){return(t=ce(t))in e?Object.defineProperty(e,t,{value:r,enumerable:!0,configurable:!0,writable:!0}):e[t]=r,e}function pe(e){if(Array.isArray(e))return e}function fe(e,t){var r=e==null?null:typeof Symbol<"u"&&e[Symbol.iterator]||e["@@iterator"];if(r!=null){var a,o,N,d,m=[],v=!0,g=!1;try{if(N=(r=r.call(e)).next,t!==0)for(;!(v=(a=N.call(r)).done)&&(m.push(a.value),m.length!==t);v=!0);}catch(h){g=!0,o=h}finally{try{if(!v&&r.return!=null&&(d=r.return(),Object(d)!==d))return}finally{if(g)throw o}}return m}}function J(e,t){(t==null||t>e.length)&&(t=e.length);for(var r=0,a=Array(t);r<t;r++)a[r]=e[r];return a}function be(e,t){if(e){if(typeof e=="string")return J(e,t);var r={}.toString.call(e).slice(8,-1);return r==="Object"&&e.constructor&&(r=e.constructor.name),r==="Map"||r==="Set"?Array.from(e):r==="Arguments"||/^(?:Ui|I)nt(?:8|16|32)(?:Clamped)?Array$/.test(r)?J(e,t):void 0}}function de(){throw new TypeError(`Invalid attempt to destructure non-iterable instance.
In order to be iterable, non-array objects must have a [Symbol.iterator]() method.`)}function ye(e,t){return pe(e)||fe(e,t)||be(e,t)||de()}var ve={icon:"p-menuitem-icon",action:"p-menuitem-link",label:"p-menuitem-text",home:function(t){var r=t._className,a=t.disabled;return B("p-breadcrumb-home p-menuitem",{"p-disabled":a},r)},separatorIcon:"p-breadcrumb-chevron",separator:"p-menuitem-separator",menuitem:function(t){var r=t.item;return B("p-menuitem",r.className,{"p-disabled":r.disabled})},menu:"p-breadcrumb-list",root:"p-breadcrumb p-component"},ge=`
@layer primereact {
    .p-breadcrumb {
        overflow-x: auto;
        display: flex;
    }

    .p-breadcrumb ol {
        margin: 0;
        padding: 0;
        list-style-type: none;
        display: flex;
        align-items: center;
        flex-wrap: nowrap;
    }

    .p-breadcrumb .p-menuitem-text {
        line-height: 1;
    }

    .p-breadcrumb .p-menuitem-link {
        text-decoration: none;
        display: flex;
        align-items: center;
    }

    .p-breadcrumb .p-menuitem-separator {
        display: flex;
        align-items: center;
    }

    .p-breadcrumb::-webkit-scrollbar {
        display: none;
    }
}
`,j=ie.extend({defaultProps:{__TYPE:"BreadCrumb",id:null,model:null,home:null,separatorIcon:null,style:null,className:null,children:void 0},css:{classes:ve,styles:ge}});function X(e,t){var r=Object.keys(e);if(Object.getOwnPropertySymbols){var a=Object.getOwnPropertySymbols(e);t&&(a=a.filter(function(o){return Object.getOwnPropertyDescriptor(e,o).enumerable})),r.push.apply(r,a)}return r}function $(e){for(var t=1;t<arguments.length;t++){var r=arguments[t]!=null?arguments[t]:{};t%2?X(Object(r),!0).forEach(function(a){me(e,a,r[a])}):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(r)):X(Object(r)).forEach(function(a){Object.defineProperty(e,a,Object.getOwnPropertyDescriptor(r,a))})}return e}var he=l.memo(l.forwardRef(function(e,t){var r=te(),a=l.useContext(ne),o=j.getProps(e,a),N=l.useState(o.id),d=ye(N,2),m=d[0],v=d[1],g=l.useRef(null),h=j.setMetaData({props:o,state:{id:m}}),s=h.ptm,u=h.cx,K=h.isUnstyled;ae(j.css.styles,K,{name:"breadcrumb"});var k=function(n,i){if(i.disabled){n.preventDefault();return}i.command&&i.command({originalEvent:n,item:i}),i.url||(n.preventDefault(),n.stopPropagation())},M=function(n){var i=typeof window<"u"?window.location.pathname:"";return n===i?"page":void 0},L=function(){var n=o.home;if(n){if(n.visible===!1)return null;var i=n.icon,c=n.target,f=n.url,b=n.disabled,p=n.style,_=n.className,P=n.template,E=n.label,I=r({className:u("icon")},s("icon")),C=U.getJSXIcon(i,$({},I),{props:o}),G=r({href:f||"#",className:u("action"),"aria-disabled":b,"aria-current":M(f),target:c,onClick:function(A){return k(A,n)}},s("action")),Q=r({className:u("label")},s("label")),V=E&&l.createElement("span",Q,E),x=l.createElement("a",G,C,V);if(P){var Z={onClick:function(A){return k(A,n)},className:"p-menuitem-link",labelClassName:"p-menuitem-text",element:x,props:o};x=H.getJSXElement(P,n,Z)}var T=m+"_home",ee=r({id:T,className:u("home",{_className:_,disabled:b}),style:p},s("home"));return l.createElement("li",S({},ee,{key:T}),x)}return null},R=function(n){var i=m+"_sep_"+n,c=r({className:u("separatorIcon"),"aria-hidden":"true"},s("separatorIcon")),f=o.separatorIcon||l.createElement(se,c),b=U.getJSXIcon(f,$({},c),{props:o}),p=r({id:i,className:u("separator"),role:"separator"},s("separator"));return l.createElement("li",S({},p,{key:i}),b)},q=function(n,i){if(n.visible===!1)return null;var c=r({className:u("label")},s("label")),f=n.label&&l.createElement("span",c,n.label),b=r({href:n.url||"#",className:u("action"),target:n.target,"aria-current":M(n.url),onClick:function(C){return k(C,n)},"aria-disabled":n.disabled,tabIndex:n.disabled?-1:void 0},s("action")),p=l.createElement("a",b,f);if(n.template){var _={onClick:function(C){return k(C,n)},className:"p-menuitem-link",labelClassName:"p-menuitem-text",element:p,props:o};p=H.getJSXElement(n.template,n,_)}var P=n.id||m+"_"+i,E=r({id:P,className:u("menuitem",{item:n}),style:n.style},s("menuitem"));return l.createElement("li",S({},E,{key:P}),p)},F=function(){if(o.model){var n=o.model.map(function(i,c){if(i.visible===!1)return null;var f=q(i,c),b=c===o.model.length-1?null:R(c),p=m+"_"+c;return l.createElement(l.Fragment,{key:p},f,b)});return n}return null};oe(function(){m||v(le())}),l.useImperativeHandle(t,function(){return{props:o,getElement:function(){return g.current}}});var D=L(),w=F(),W=R("home"),Y=r({className:u("menu")},s("menu")),z=r({id:o.id,ref:g,className:B(o.className,u("root")),style:o.style},j.getOtherProps(o),s("root"));return l.createElement("nav",z,l.createElement("ol",Y,D,D&&!!(w!=null&&w.length)&&W,w))}));he.displayName="BreadCrumb";export{he as B};
