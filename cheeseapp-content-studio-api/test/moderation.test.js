import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
const env={SUPABASE_URL:'https://project.invalid',SUPABASE_PUBLISHABLE_KEY:'public-test',SUPABASE_SERVICE_ROLE_KEY:'sb_secret_test',ALLOWED_ORIGINS:'https://studio.cheeseapp.org'};
async function run(role,path,init={}) {
 const calls=[]; const original=globalThis.fetch;
 globalThis.fetch=async (url,options)=>{
  calls.push({url:String(url),options});
  if(String(url).endsWith('/auth/v1/user'))return Response.json({id:'11111111-1111-4111-8111-111111111111',user_metadata:{role:'admin'}});
  if(String(url).includes('/content_studio_roles?'))return Response.json(role?[{role}]:[]);
  if(String(url).includes('/rpc/moderation_report_media'))return Response.json([{bucket:'chat-images',object_path:'reported/photo.jpg'}]);
  if(String(url).includes('/storage/v1/object/'))return new Response(new Uint8Array([255,216,255]),{headers:{'Content-Type':'image/jpeg'}});
  return Response.json([]);
 };
 try {const response=await worker.fetch(new Request('https://api.invalid'+path,{...init,headers:{Authorization:'Bearer synthetic-user-session','Content-Type':'application/json',...init.headers}}),env);return {response,calls};}
 finally{globalThis.fetch=original;}
}
test('unapproved account cannot promote itself with user metadata',async()=>{
 const {response,calls}=await run(null,'/v1/moderation');assert.equal(response.status,403);assert.equal(calls.length,2);
});
test('editor cannot read reports or private report media',async()=>{
 for(const path of ['/v1/moderation','/v1/moderation/media?kind=message&id=11111111-1111-4111-8111-111111111111&index=0']) {
  const {response,calls}=await run('editor',path);assert.equal(response.status,403);assert.equal(calls.length,2);
 }
});
test('administrator moderation RPC retains user identity and storage uses API-key-only secret',async()=>{
 const {response,calls}=await run('admin','/v1/moderation/media?kind=message&id=11111111-1111-4111-8111-111111111111&index=0');
 assert.equal(response.status,200);assert.equal(response.headers.get('Cache-Control'),'private, no-store');
 assert.equal(calls[2].options.headers.Authorization,'Bearer synthetic-user-session');
 assert.equal(calls[3].options.headers.Authorization,undefined);assert.match(calls[3].url,/chat-images\/reported\/photo.jpg$/);
});
test('client cannot request a media path outside the report',async()=>{
 const {response,calls}=await run('admin','/v1/moderation/media?kind=message&id=11111111-1111-4111-8111-111111111111&index=8&path=another-person');assert.equal(response.status,404);assert.equal(calls.length,3);
});
test('moderation requires an explanatory note before calling a write RPC',async()=>{
 const {response,calls}=await run('admin','/v1/moderation/resolve',{method:'POST',body:JSON.stringify({kind:'user',id:'11111111-1111-4111-8111-111111111111',action:'suspend',note:''})});assert.equal(response.status,400);assert.equal(calls.length,2);
});
test('Content Studio no longer exposes the optional Gemini consent API',async()=>{
 const {response,calls}=await run('editor','/v1/ai-consent');
 assert.equal(response.status,404);
 assert.equal(calls.some(call=>call.url.includes('ai_processing_consents')||call.url.includes('set_my_ai_consent')),false);
});
