const commons = require('../utils/common.js')

let bytes8 = commons.StringToBytes(process.argv[2], 8);
console.log(bytes8);
