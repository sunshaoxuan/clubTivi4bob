/// Native build identity retained for compatibility with installed updaters.
const bobTvVersion = '1.4.4+6';

/// Public version shown throughout BobTV.
const bobTvDisplayVersion = '1.4.4';

String displayBobTvVersion(String value) =>
    value.replaceAll(RegExp(r'(?<=\d)\+\d+'), '');
