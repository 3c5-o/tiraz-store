import {cors,json} from './shared.ts';
// Owner provisioning is complete; it cannot reopen when an owner is disabled.
Deno.serve(req=>req.method==='OPTIONS'?new Response('ok',{headers:cors}):json({error:'OWNER_EXISTS'},409));
