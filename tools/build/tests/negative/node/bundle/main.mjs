// Imports a module that is not staged: esbuild_bundle `unresolved_import`
// must fail to build.
import { absent } from './absent.mjs';

console.log(absent);
