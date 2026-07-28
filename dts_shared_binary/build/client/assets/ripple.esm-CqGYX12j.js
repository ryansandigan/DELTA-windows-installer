import{r as c}from"./chunk-JZWAC4HX-B9gBqAB-.js";import{u as N,P as U,f as W,g as $,b as B,d as S,e as Y,c as K,C as X,O as R,D as a}from"./iconbase.esm-BPTj-nSg.js";function P(){return P=Object.assign?Object.assign.bind():function(e){for(var t=1;t<arguments.length;t++){var r=arguments[t];for(var n in r)({}).hasOwnProperty.call(r,n)&&(e[n]=r[n])}return e},P.apply(null,arguments)}function d(e){"@babel/helpers - typeof";return d=typeof Symbol=="function"&&typeof Symbol.iterator=="symbol"?function(t){return typeof t}:function(t){return t&&typeof Symbol=="function"&&t.constructor===Symbol&&t!==Symbol.prototype?"symbol":typeof t},d(e)}function q(e,t){if(d(e)!="object"||!e)return e;var r=e[Symbol.toPrimitive];if(r!==void 0){var n=r.call(e,t);if(d(n)!="object")return n;throw new TypeError("@@toPrimitive must return a primitive value.")}return(t==="string"?String:Number)(e)}function z(e){var t=q(e,"string");return d(t)=="symbol"?t:t+""}function F(e,t,r){return(t=z(t))in e?Object.defineProperty(e,t,{value:r,enumerable:!0,configurable:!0,writable:!0}):e[t]=r,e}function G(e){if(Array.isArray(e))return e}function J(e,t){var r=e==null?null:typeof Symbol<"u"&&e[Symbol.iterator]||e["@@iterator"];if(r!=null){var n,l,v,o,i=[],m=!0,p=!1;try{if(v=(r=r.call(e)).next,t!==0)for(;!(m=(n=v.call(r)).done)&&(i.push(n.value),i.length!==t);m=!0);}catch(y){p=!0,l=y}finally{try{if(!m&&r.return!=null&&(o=r.return(),Object(o)!==o))return}finally{if(p)throw l}}return i}}function k(e,t){(t==null||t>e.length)&&(t=e.length);for(var r=0,n=Array(t);r<t;r++)n[r]=e[r];return n}function Q(e,t){if(e){if(typeof e=="string")return k(e,t);var r={}.toString.call(e).slice(8,-1);return r==="Object"&&e.constructor&&(r=e.constructor.name),r==="Map"||r==="Set"?Array.from(e):r==="Arguments"||/^(?:Ui|I)nt(?:8|16|32)(?:Clamped)?Array$/.test(r)?k(e,t):void 0}}function V(){throw new TypeError(`Invalid attempt to destructure non-iterable instance.
In order to be iterable, non-array objects must have a [Symbol.iterator]() method.`)}function Z(e,t){return G(e)||J(e,t)||Q(e,t)||V()}var ee=`
@layer primereact {
    .p-ripple {
        overflow: hidden;
        position: relative;
    }
    
    .p-ink {
        display: block;
        position: absolute;
        background: rgba(255, 255, 255, 0.5);
        border-radius: 100%;
        transform: scale(0);
    }
    
    .p-ink-active {
        animation: ripple 0.4s linear;
    }
    
    .p-ripple-disabled .p-ink {
        display: none;
    }
}

@keyframes ripple {
    100% {
        opacity: 0;
        transform: scale(2.5);
    }
}

`,te={root:"p-ink"},f=X.extend({defaultProps:{__TYPE:"Ripple",children:void 0},css:{styles:ee,classes:te},getProps:function(t){return R.getMergedProps(t,f.defaultProps)},getOtherProps:function(t){return R.getDiffProps(t,f.defaultProps)}});function x(e,t){var r=Object.keys(e);if(Object.getOwnPropertySymbols){var n=Object.getOwnPropertySymbols(e);t&&(n=n.filter(function(l){return Object.getOwnPropertyDescriptor(e,l).enumerable})),r.push.apply(r,n)}return r}function re(e){for(var t=1;t<arguments.length;t++){var r=arguments[t]!=null?arguments[t]:{};t%2?x(Object(r),!0).forEach(function(n){F(e,n,r[n])}):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(r)):x(Object(r)).forEach(function(n){Object.defineProperty(e,n,Object.getOwnPropertyDescriptor(r,n))})}return e}var ne=c.memo(c.forwardRef(function(e,t){var r=c.useState(!1),n=Z(r,2),l=n[0],v=n[1],o=c.useRef(null),i=c.useRef(null),m=N(),p=c.useContext(U),y=f.getProps(e,p),h=p&&p.ripple||W.ripple,_={props:y};$(f.css.styles,{name:"ripple",manual:!h});var O=f.setMetaData(re({},_)),A=O.ptm,D=O.cx,j=function(){return o.current&&o.current.parentElement},w=function(){i.current&&i.current.addEventListener("pointerdown",E)},T=function(){i.current&&i.current.removeEventListener("pointerdown",E)},E=function(u){var g=a.getOffset(i.current),H=u.pageX-g.left+document.body.scrollTop-a.getWidth(o.current)/2,L=u.pageY-g.top+document.body.scrollLeft-a.getHeight(o.current)/2;C(H,L)},C=function(u,g){!o.current||getComputedStyle(o.current,null).display==="none"||(a.removeClass(o.current,"p-ink-active"),b(),o.current.style.top=g+"px",o.current.style.left=u+"px",a.addClass(o.current,"p-ink-active"))},M=function(u){a.removeClass(u.currentTarget,"p-ink-active")},b=function(){if(o.current&&!a.getHeight(o.current)&&!a.getWidth(o.current)){var u=Math.max(a.getOuterWidth(i.current),a.getOuterHeight(i.current));o.current.style.height=u+"px",o.current.style.width=u+"px"}};if(c.useImperativeHandle(t,function(){return{props:y,getInk:function(){return o.current},getTarget:function(){return i.current}}}),B(function(){v(!0)}),S(function(){l&&o.current&&(i.current=j(),b(),w())},[l]),S(function(){o.current&&!i.current&&(i.current=j(),b(),w())}),Y(function(){o.current&&(i.current=null,T())}),!h)return null;var I=m({"aria-hidden":!0,className:K(D("root"))},f.getOtherProps(y),A("root"));return c.createElement("span",P({role:"presentation",ref:o},I,{onAnimationEnd:M}))}));ne.displayName="Ripple";export{ne as R};
