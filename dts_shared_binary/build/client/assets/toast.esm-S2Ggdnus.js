import{r as s,R as A}from"./chunk-JZWAC4HX-B9gBqAB-.js";import{u as le,P as Ne,a as we,d as Pe,Z as D,f as U,e as Te,C as _e,O as F,c as V,v as Oe,h as re,s as Me,D as oe}from"./iconbase.esm-BPTj-nSg.js";import{_ as je,a as Re,b as ke,T as ae,C as Ae}from"./csstransition.esm-BzDCZEIq.js";import{P as De}from"./portal.esm-QfSYADz4.js";import{C as Le}from"./index.esm-CfVYN8q7.js";import{T as Fe,E as Ue,I as Ve}from"./index.esm-CB3paqDm.js";import{T as He}from"./index.esm-DBZmZH-v.js";import{R as $e}from"./ripple.esm-CqGYX12j.js";import{P}from"./index-Cv2Og7ZH.js";function Be(e){if(e===void 0)throw new ReferenceError("this hasn't been initialised - super() hasn't been called");return e}function K(e,n){var t=function(a){return n&&s.isValidElement(a)?n(a):a},o=Object.create(null);return e&&s.Children.map(e,function(r){return r}).forEach(function(r){o[r.key]=t(r)}),o}function Ze(e,n){e=e||{},n=n||{};function t(u){return u in n?n[u]:e[u]}var o=Object.create(null),r=[];for(var a in e)a in n?r.length&&(o[a]=r,r=[]):r.push(a);var i,l={};for(var c in n){if(o[c])for(i=0;i<o[c].length;i++){var p=o[c][i];l[o[c][i]]=t(p)}l[c]=t(c)}for(i=0;i<r.length;i++)l[r[i]]=t(r[i]);return l}function I(e,n,t){return t[n]!=null?t[n]:e.props[n]}function Xe(e,n){return K(e.children,function(t){return s.cloneElement(t,{onExited:n.bind(null,t),in:!0,appear:I(t,"appear",e),enter:I(t,"enter",e),exit:I(t,"exit",e)})})}function We(e,n,t){var o=K(e.children),r=Ze(n,o);return Object.keys(r).forEach(function(a){var i=r[a];if(s.isValidElement(i)){var l=a in n,c=a in o,p=n[a],u=s.isValidElement(p)&&!p.props.in;c&&(!l||u)?r[a]=s.cloneElement(i,{onExited:t.bind(null,i),in:!0,exit:I(i,"exit",e),enter:I(i,"enter",e)}):!c&&l&&!u?r[a]=s.cloneElement(i,{in:!1}):c&&l&&s.isValidElement(p)&&(r[a]=s.cloneElement(i,{onExited:t.bind(null,i),in:p.props.in,exit:I(i,"exit",e),enter:I(i,"enter",e)}))}}),r}var ze=Object.values||function(e){return Object.keys(e).map(function(n){return e[n]})},Je={component:"div",childFactory:function(n){return n}},ee=(function(e){je(n,e);function n(o,r){var a;a=e.call(this,o,r)||this;var i=a.handleExited.bind(Be(a));return a.state={contextValue:{isMounting:!0},handleExited:i,firstRender:!0},a}var t=n.prototype;return t.componentDidMount=function(){this.mounted=!0,this.setState({contextValue:{isMounting:!1}})},t.componentWillUnmount=function(){this.mounted=!1},n.getDerivedStateFromProps=function(r,a){var i=a.children,l=a.handleExited,c=a.firstRender;return{children:c?Xe(r,l):We(r,i,l),firstRender:!1}},t.handleExited=function(r,a){var i=K(this.props.children);r.key in i||(r.props.onExited&&r.props.onExited(a),this.mounted&&this.setState(function(l){var c=Re({},l.children);return delete c[r.key],{children:c}}))},t.render=function(){var r=this.props,a=r.component,i=r.childFactory,l=ke(r,["component","childFactory"]),c=this.state.contextValue,p=ze(this.state.children).map(i);return delete l.appear,delete l.enter,delete l.exit,a===null?A.createElement(ae.Provider,{value:c},p):A.createElement(ae.Provider,{value:c},A.createElement(a,l,p))},n})(A.Component);ee.propTypes={component:P.any,children:P.node,appear:P.bool,enter:P.bool,exit:P.bool,childFactory:P.func};ee.defaultProps=Je;function Y(){return Y=Object.assign?Object.assign.bind():function(e){for(var n=1;n<arguments.length;n++){var t=arguments[n];for(var o in t)({}).hasOwnProperty.call(t,o)&&(e[o]=t[o])}return e},Y.apply(null,arguments)}function q(e,n){(n==null||n>e.length)&&(n=e.length);for(var t=0,o=Array(n);t<n;t++)o[t]=e[t];return o}function Ge(e){if(Array.isArray(e))return q(e)}function Ye(e){if(typeof Symbol<"u"&&e[Symbol.iterator]!=null||e["@@iterator"]!=null)return Array.from(e)}function ce(e,n){if(e){if(typeof e=="string")return q(e,n);var t={}.toString.call(e).slice(8,-1);return t==="Object"&&e.constructor&&(t=e.constructor.name),t==="Map"||t==="Set"?Array.from(e):t==="Arguments"||/^(?:Ui|I)nt(?:8|16|32)(?:Clamped)?Array$/.test(t)?q(e,n):void 0}}function qe(){throw new TypeError(`Invalid attempt to spread non-iterable instance.
In order to be iterable, non-array objects must have a [Symbol.iterator]() method.`)}function G(e){return Ge(e)||Ye(e)||ce(e)||qe()}function Qe(e){if(Array.isArray(e))return e}function Ke(e,n){var t=e==null?null:typeof Symbol<"u"&&e[Symbol.iterator]||e["@@iterator"];if(t!=null){var o,r,a,i,l=[],c=!0,p=!1;try{if(a=(t=t.call(e)).next,n===0){if(Object(t)!==t)return;c=!1}else for(;!(c=(o=a.call(t)).done)&&(l.push(o.value),l.length!==n);c=!0);}catch(u){p=!0,r=u}finally{try{if(!c&&t.return!=null&&(i=t.return(),Object(i)!==i))return}finally{if(p)throw r}}return l}}function et(){throw new TypeError(`Invalid attempt to destructure non-iterable instance.
In order to be iterable, non-array objects must have a [Symbol.iterator]() method.`)}function Q(e,n){return Qe(e)||Ke(e,n)||ce(e,n)||et()}function _(e){"@babel/helpers - typeof";return _=typeof Symbol=="function"&&typeof Symbol.iterator=="symbol"?function(n){return typeof n}:function(n){return n&&typeof Symbol=="function"&&n.constructor===Symbol&&n!==Symbol.prototype?"symbol":typeof n},_(e)}function tt(e,n){if(_(e)!="object"||!e)return e;var t=e[Symbol.toPrimitive];if(t!==void 0){var o=t.call(e,n);if(_(o)!="object")return o;throw new TypeError("@@toPrimitive must return a primitive value.")}return(n==="string"?String:Number)(e)}function nt(e){var n=tt(e,"string");return _(n)=="symbol"?n:n+""}function ue(e,n,t){return(n=nt(n))in e?Object.defineProperty(e,n,{value:t,enumerable:!0,configurable:!0,writable:!0}):e[n]=t,e}var rt=`
@layer primereact {
    .p-toast {
        width: calc(100% - var(--toast-indent, 0px));
        max-width: 25rem;
    }
    
    .p-toast-message-icon {
        flex-shrink: 0;
    }
    
    .p-toast-message-content {
        display: flex;
        align-items: flex-start;
    }
    
    .p-toast-message-text {
        flex: 1 1 auto;
    }
    
    .p-toast-summary {
        overflow-wrap: anywhere;
    }
    
    .p-toast-detail {
        overflow-wrap: anywhere;
    }
    
    .p-toast-top-center {
        transform: translateX(-50%);
    }
    
    .p-toast-bottom-center {
        transform: translateX(-50%);
    }
    
    .p-toast-center {
        min-width: 20vw;
        transform: translate(-50%, -50%);
    }
    
    .p-toast-icon-close {
        display: flex;
        align-items: center;
        justify-content: center;
        overflow: hidden;
        position: relative;
    }
    
    .p-toast-icon-close.p-link {
        cursor: pointer;
    }
    
    /* Animations */
    .p-toast-message-enter {
        opacity: 0;
        transform: translateY(50%);
    }
    
    .p-toast-message-enter-active {
        opacity: 1;
        transform: translateY(0);
        transition: transform 0.3s, opacity 0.3s;
    }
    
    .p-toast-message-enter-done {
        transform: none;
    }
    
    .p-toast-message-exit {
        opacity: 1;
        max-height: 1000px;
    }
    
    .p-toast .p-toast-message.p-toast-message-exit-active {
        opacity: 0;
        max-height: 0;
        margin-bottom: 0;
        overflow: hidden;
        transition: max-height 0.45s cubic-bezier(0, 1, 0, 1), opacity 0.3s, margin-bottom 0.3s;
    }
}
`,ot={root:function(n){var t=n.props,o=n.context;return V("p-toast p-component p-toast-"+t.position,t.className,{"p-input-filled":o&&o.inputStyle==="filled"||U.inputStyle==="filled","p-ripple-disabled":o&&o.ripple===!1||U.ripple===!1})},message:{message:function(n){var t=n.severity;return V("p-toast-message",ue({},"p-toast-message-".concat(t),t))},content:"p-toast-message-content",buttonicon:"p-toast-icon-close-icon",closeButton:"p-toast-icon-close p-link",icon:"p-toast-message-icon",text:"p-toast-message-text",summary:"p-toast-summary",detail:"p-toast-detail"},transition:"p-toast-message"},at={root:function(n){var t=n.props;return{position:"fixed",top:t.position==="top-right"||t.position==="top-left"||t.position==="top-center"?"20px":t.position==="center"?"50%":null,right:(t.position==="top-right"||t.position==="bottom-right")&&"20px",bottom:(t.position==="bottom-left"||t.position==="bottom-right"||t.position==="bottom-center")&&"20px",left:t.position==="top-left"||t.position==="bottom-left"?"20px":t.position==="center"||t.position==="top-center"||t.position==="bottom-center"?"50%":null}}},L=_e.extend({defaultProps:{__TYPE:"Toast",id:null,className:null,content:null,style:null,baseZIndex:0,position:"top-right",transitionOptions:null,appendTo:"self",onClick:null,onRemove:null,onShow:null,onHide:null,onMouseEnter:null,onMouseLeave:null,children:void 0},css:{classes:ot,styles:rt,inlineStyles:at}});function se(e,n){var t=Object.keys(e);if(Object.getOwnPropertySymbols){var o=Object.getOwnPropertySymbols(e);n&&(o=o.filter(function(r){return Object.getOwnPropertyDescriptor(e,r).enumerable})),t.push.apply(t,o)}return t}function d(e){for(var n=1;n<arguments.length;n++){var t=arguments[n]!=null?arguments[n]:{};n%2?se(Object(t),!0).forEach(function(o){ue(e,o,t[o])}):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(t)):se(Object(t)).forEach(function(o){Object.defineProperty(e,o,Object.getOwnPropertyDescriptor(t,o))})}return e}var me=s.memo(s.forwardRef(function(e,n){var t=le(),o=e.messageInfo,r=e.metaData,a=e.ptCallbacks,i=a.ptm,l=a.ptmo,c=a.cx,p=e.index,u=o.message,b=u.severity,H=u.content,O=u.summary,M=u.detail,$=u.closable,j=u.life,T=u.sticky,B=u.className,Z=u.style,X=u.contentClassName,W=u.contentStyle,y=u.icon,m=u.closeIcon,f=u.pt,h={index:p},v=d(d({},r),h),x=s.useState(!1),N=Q(x,2),R=N[0],k=N[1],pe=Oe(function(){z()},j||3e3,!T&&!R),fe=Q(pe,1),te=fe[0],C=function(g,E){return i(g,d({hostName:e.hostName},E))},z=function(){te(),e.onClose&&e.onClose(o)},ne=function(g){e.onClick&&!(oe.hasClass(g.target,"p-toast-icon-close")||oe.hasClass(g.target,"p-toast-icon-close-icon"))&&e.onClick(o.message)},de=function(g){e.onMouseEnter&&e.onMouseEnter(g),!g.defaultPrevented&&(T||(te(),k(!0)))},ve=function(g){e.onMouseLeave&&e.onMouseLeave(g),!g.defaultPrevented&&(T||k(!1))},he=function(){var g=t({className:c("message.buttonicon")},C("buttonicon",v),l(f,"buttonicon",d(d({},h),{},{hostName:e.hostName}))),E=m||s.createElement(He,g),S=re.getJSXIcon(E,d({},g),{props:e}),J=t({type:"button",className:c("message.closeButton"),onClick:z,"aria-label":e.ariaCloseLabel||Me("close")},C("closeButton",v),l(f,"closeButton",d(d({},h),{},{hostName:e.hostName})));return $!==!1?s.createElement("div",null,s.createElement("button",J,S,s.createElement($e,null))):null},ge=function(){if(o){var g=F.getJSXElement(H,{message:o.message,onClick:ne,onClose:z}),E=t({className:c("message.icon")},C("icon",v),l(f,"icon",d(d({},h),{},{hostName:e.hostName}))),S=y;if(!y)switch(b){case"info":S=s.createElement(Ve,E);break;case"warn":S=s.createElement(Ue,E);break;case"error":S=s.createElement(Fe,E);break;case"success":S=s.createElement(Le,E);break}var J=re.getJSXIcon(S,d({},E),{props:e}),Ce=t({className:c("message.text")},C("text",v),l(f,"text",d(d({},h),{},{hostName:e.hostName}))),Se=t({className:c("message.summary")},C("summary",v),l(f,"summary",d(d({},h),{},{hostName:e.hostName}))),Ie=t({className:c("message.detail")},C("detail",v),l(f,"detail",d(d({},h),{},{hostName:e.hostName})));return g||s.createElement(s.Fragment,null,J,s.createElement("div",Ce,s.createElement("span",Se,O),M&&s.createElement("div",Ie,M)))}return null},ye=ge(),be=he(),Ee=t({ref:n,className:V(B,c("message.message",{severity:b})),style:Z,role:"alert","aria-live":"assertive","aria-atomic":"true",onClick:ne,onMouseEnter:de,onMouseLeave:ve},C("message",v),l(f,"root",d(d({},h),{},{hostName:e.hostName}))),xe=t({className:V(X,c("message.content")),style:W},C("content",v),l(f,"content",d(d({},h),{},{hostName:e.hostName})));return s.createElement("div",Ee,s.createElement("div",xe,ye,be))}));me.displayName="ToastMessage";var ie=0,st=s.memo(s.forwardRef(function(e,n){var t=le(),o=s.useContext(Ne),r=L.getProps(e,o),a=s.useState([]),i=Q(a,2),l=i[0],c=i[1],p=s.useRef(null),u={props:r,state:{messages:l}},b=L.setMetaData(u);we(L.css.styles,b.isUnstyled,{name:"toast"});var H=function(m){m&&c(function(f){return O(f,m,!0)})},O=function(m,f,h){var v;if(Array.isArray(f)){var x=f.reduce(function(R,k){return R.push({_pId:ie++,message:k}),R},[]);h?v=m?[].concat(G(m),G(x)):x:v=x}else{var N={_pId:ie++,message:f};h?v=m?[].concat(G(m),[N]):[N]:v=[N]}return v},M=function(){D.clear(p.current),c([])},$=function(m){c(function(f){return O(f,m,!1)})},j=function(m){var f=F.isNotEmpty(m._pId)?m._pId:m.message||m;c(function(h){return h.filter(function(v){return v._pId!==m._pId&&!F.deepEquals(v.message,f)})}),r.onRemove&&r.onRemove(m.message||f)},T=function(m){j(m)},B=function(){r.onShow&&r.onShow()},Z=function(){l.length===1&&D.clear(p.current),r.onHide&&r.onHide()};Pe(function(){D.set("toast",p.current,o&&o.autoZIndex||U.autoZIndex,r.baseZIndex||o&&o.zIndex.toast||U.zIndex.toast)},[l,r.baseZIndex]),Te(function(){D.clear(p.current)}),s.useImperativeHandle(n,function(){return{props:r,show:H,replace:$,remove:j,clear:M,getElement:function(){return p.current}}});var X=function(){var m=t({ref:p,id:r.id,className:b.cx("root",{context:o}),style:b.sx("root")},L.getOtherProps(r),b.ptm("root")),f=t({classNames:b.cx("transition"),timeout:{enter:300,exit:300},options:r.transitionOptions,unmountOnExit:!0,onEntered:B,onExited:Z},b.ptm("transition"));return s.createElement("div",m,s.createElement(ee,null,l&&l.map(function(h,v){var x=s.createRef();return s.createElement(Ae,Y({nodeRef:x,key:h._pId},f),e.content?F.getJSXElement(e.content,{message:h.message}):s.createElement(me,{hostName:"Toast",ref:x,messageInfo:h,index:v,onClick:r.onClick,onClose:T,onMouseEnter:r.onMouseEnter,onMouseLeave:r.onMouseLeave,closeIcon:r.closeIcon,ptCallbacks:b,metaData:u}))})))},W=X();return s.createElement(De,{element:W,appendTo:r.appendTo})}));st.displayName="Toast";export{st as T};
