import{r as i}from"./chunk-JZWAC4HX-B9gBqAB-.js";import{u as g,P as h,a as b,C as x,c as z}from"./iconbase.esm-BPTj-nSg.js";var P={root:function(t){var e=t.props,r=t.horizontal,n=t.vertical;return z("p-divider p-component p-divider-".concat(e.layout," p-divider-").concat(e.type),{"p-divider-left":r&&(!e.align||e.align==="left"),"p-divider-right":r&&e.align==="right","p-divider-center":r&&e.align==="center"||n&&(!e.align||e.align==="center"),"p-divider-top":n&&e.align==="top","p-divider-bottom":n&&e.align==="bottom"},e.className)},content:"p-divider-content"},D=`
@layer primereact {
    .p-divider-horizontal {
        display: flex;
        width: 100%;
        position: relative;
        align-items: center;
    }
    
    .p-divider-horizontal:before {
        position: absolute;
        display: block;
        top: 50%;
        left: 0;
        width: 100%;
        content: "";
    }
    
    .p-divider-horizontal.p-divider-left {
        justify-content: flex-start;
    }
    
    .p-divider-horizontal.p-divider-right {
        justify-content: flex-end;
    }
    
    .p-divider-horizontal.p-divider-center {
        justify-content: center;
    }
    
    .p-divider-content {
        z-index: 1;
    }
    
    .p-divider-vertical {
        min-height: 100%;
        margin: 0 1rem;
        display: flex;
        position: relative;
        justify-content: center;
    }
    
    .p-divider-vertical:before {
        position: absolute;
        display: block;
        top: 0;
        left: 50%;
        height: 100%;
        content: "";
    }
    
    .p-divider-vertical.p-divider-top {
        align-items: flex-start;
    }
    
    .p-divider-vertical.p-divider-center {
        align-items: center;
    }
    
    .p-divider-vertical.p-divider-bottom {
        align-items: flex-end;
    }
    
    .p-divider-solid.p-divider-horizontal:before {
        border-top-style: solid;
    }
    
    .p-divider-solid.p-divider-vertical:before {
        border-left-style: solid;
    }
    
    .p-divider-dashed.p-divider-horizontal:before {
        border-top-style: dashed;
    }
    
    .p-divider-dashed.p-divider-vertical:before {
        border-left-style: dashed;
    }
    
    .p-divider-dotted.p-divider-horizontal:before {
        border-top-style: dotted;
    }
    
    .p-divider-dotted.p-divider-horizontal:before {
        border-left-style: dotted;
    }
}
`,E={root:function(t){var e=t.props;return{justifyContent:e.layout==="horizontal"?e.align==="center"||e.align===null?"center":e.align==="left"?"flex-start":e.align==="right"?"flex-end":null:null,alignItems:e.layout==="vertical"?e.align==="center"||e.align===null?"center":e.align==="top"?"flex-start":e.align==="bottom"?"flex-end":null:null}}},l=x.extend({defaultProps:{__TYPE:"Divider",align:null,layout:"horizontal",type:"solid",style:null,className:null,children:void 0},css:{classes:P,styles:D,inlineStyles:E}}),N=i.forwardRef(function(a,t){var e=g(),r=i.useContext(h),n=l.getProps(a,r),o=l.setMetaData({props:n}),d=o.ptm,s=o.cx,v=o.sx,c=o.isUnstyled;b(l.css.styles,c,{name:"divider"});var p=i.useRef(null),f=n.layout==="horizontal",u=n.layout==="vertical";i.useImperativeHandle(t,function(){return{props:n,getElement:function(){return p.current}}});var m=e({ref:p,style:v("root"),className:s("root",{horizontal:f,vertical:u}),"aria-orientation":n.layout,role:"separator"},l.getOtherProps(n),d("root")),y=e({className:s("content")},d("content"));return i.createElement("div",m,i.createElement("div",y,n.children))});N.displayName="Divider";export{N as D};
