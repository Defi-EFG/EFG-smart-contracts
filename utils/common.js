
/* converts string to bytes, padds with zero at end*/
function StringToBytes(name, numberOfButes) {
    if (name.length > numberOfButes) {
        return false;
    }
    let bString = Buffer.from(name, 'utf8');
    const zeropad = Buffer.alloc(numberOfButes - name.length);
    bString = Buffer.concat([bString, zeropad]);
    return bString;
}

module.exports = {
    StringToBytes: StringToBytes,
};
