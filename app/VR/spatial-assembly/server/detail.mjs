import {validateAssembly} from './schema.mjs';

export function componentIds(assembly, rootId) {
 const ids=new Set([rootId]);let changed=true;
 while(changed){changed=false;for(const part of assembly.parts)if(ids.has(part.parentPartId)&&!ids.has(part.id)){ids.add(part.id);changed=true;}}
 return ids;
}
export function detailConflict(assembly, left, right) {
 return !left||!right||componentIds(assembly,left).has(right)||componentIds(assembly,right).has(left);
}
export const detailInstructions=`Refine ONLY the requested component into more detailed selectable subcomponents. Keep the original assembly coordinate system, scale and orientation: positions and sizes remain normalized to the WHOLE original object, not to the component. Return an assembly-shaped patch containing the refined root component with EXACTLY the requested root ID plus 2-10 meaningful subcomponents inside or attached to it. Do not return unrelated parts. Retain a thin housing/enclosure as the root when appropriate; do not cover the new detail with a solid block. Keep recognizable original dimensions and colors. Mark hidden/typical structure inferred unless exact-model sources verify it. Improve the requested educational mechanism or internals, not decorative random detail. Explain each new subcomponent's function and relationship. Bounds and sizeMeters must match the original assembly. A request to go deeper may refine an already-generated subcomponent recursively. Avoid invented precise circuitry or manufacturer-specific architecture.`;

function normalizedPart(p) {
 return {id:p.id,name:p.name||'',evidence:p.evidence,description:p.description||'',function:p.function||'',uncertainty:p.uncertainty||'',sourceIds:p.sourceIds||[],isInternal:!!p.isInternal,isHousing:!!p.isHousing,parentPartId:p.parentPartId||'',detailLevel:p.detailLevel||0,explode:p.explode,primitives:p.primitives.map(m=>({kind:m.kind,position:m.position,size:m.size,rotation:m.rotation,color:m.color,vertices:m.vertices||[],triangles:m.triangles||[]}))};
}
function equivalent(a,b) {
 if(typeof a==='number'&&typeof b==='number')return Math.abs(a-b)<=1e-6*Math.max(1,Math.abs(a),Math.abs(b));
 if(a===b)return true;
 if(!a||!b||typeof a!=='object'||typeof b!=='object'||Array.isArray(a)!==Array.isArray(b))return false;
 const keys=Object.keys(a);return keys.length===Object.keys(b).length&&keys.every(key=>Object.hasOwn(b,key)&&equivalent(a[key],b[key]));
}
export function mergeDetail(current, original, rootId, patch, requestId) {
 const root=original.parts.find(p=>p.id===rootId);
 if(!root)throw Error('The component to refine is unavailable');
 const before=componentIds(original,rootId),now=componentIds(current,rootId);
 const subtree=(assembly,ids)=>assembly.parts.filter(p=>ids.has(p.id)).map(normalizedPart).sort((a,b)=>a.id.localeCompare(b.id));
 if(!equivalent(subtree(original,before),subtree(current,now)))throw Error('This component changed while detail was generated; request detail again');
 const patchRoot=patch.parts.find(p=>p.id===rootId);
 if(!patchRoot)throw Error('Detailed result did not preserve the requested component');
 const prefix='D'+requestId.replaceAll('-','').slice(0,10);
 const sourceMap=new Map((patch.research?.sources||[]).map(s=>[s.id,prefix+'-'+s.id]));
 const replacement=patch.parts.map((p,index)=>({...p,id:p.id===rootId?rootId:prefix+'-part-'+index,parentPartId:p.id===rootId?(root.parentPartId||''):rootId,detailLevel:(root.detailLevel||0)+1,sourceIds:(p.sourceIds||[]).map(id=>sourceMap.get(id)).filter(Boolean)}));
 const parts=[];for(const part of current.parts){if(part.id===rootId)parts.push(...replacement);else if(!now.has(part.id))parts.push(part);}
 const research={...(current.research||{}),sources:[...(current.research?.sources||[]),...(patch.research?.sources||[]).map(s=>({...s,id:sourceMap.get(s.id)}))],gaps:[...new Set([...(current.research?.gaps||[]),...(patch.research?.gaps||[])])].slice(0,20)};
 return validateAssembly({...current,parts,research,revision:(current.revision||1)+1,captureId:requestId});
}
