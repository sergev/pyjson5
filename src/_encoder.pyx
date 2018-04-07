cdef enum EncType:
    ENC_TYPE_EXCEPTION
    ENC_TYPE_UNKNOWN
    ENC_TYPE_NONE
    ENC_TYPE_UNICODE
    ENC_TYPE_BOOL
    ENC_TYPE_BYTES
    ENC_TYPE_LONG
    ENC_TYPE_DECIMAL
    ENC_TYPE_FLOAT
    ENC_TYPE_DATETIME
    ENC_TYPE_MAPPING
    ENC_TYPE_SEQUENCE


cdef boolean _append_i(WriterRef writer, Py_ssize_t index) except False:
    cdef const char *s
    cdef Py_ssize_t length

    s = &ESCAPE_DCT.items[index][0]
    length = s[7]
    if length == 1:
        writer.append_c(writer, s[0])
    else:
        writer.append_s(writer, s, length)

    return True


cdef boolean _encode_unicode_impl(WriterRef writer, UCSString data, Py_ssize_t length) except False:
    cdef char buf[16]
    cdef uint32_t c
    cdef uint32_t s1, s2
    cdef Py_ssize_t index

    writer.reserve(writer, 2 + length)
    writer.append_c(writer, <char> b'"')
    for index in range(length):
        c = data[index]
        if UCSString is not UCS4String:
            _append_i(writer, c)
        else:
            if c < 0x10000:
                _append_i(writer, c)
            else:
                # surrogate pair
                c -= 0x10000
                s1 = 0xd800 | ((c >> 10) & 0x3ff)
                s2 = 0xdc00 | (c & 0x3ff)

                snprintf(buf, sizeof(buf), b'\\u%04x\\u%04x', s1, s2)
                writer.append_s(writer, buf, 2 * 6)
    writer.append_c(writer, <char> b'"')

    return True


cdef boolean _encode_unicode(WriterRef writer, object data, EncType enc_type) except False:
    cdef Py_ssize_t length
    cdef int kind

    PyUnicode_READY(data)

    length = PyUnicode_GET_LENGTH(data)
    kind = PyUnicode_KIND(data)

    if kind == PyUnicode_1BYTE_KIND:
        _encode_unicode_impl(writer, PyUnicode_1BYTE_DATA(data), length)
    elif kind == PyUnicode_2BYTE_KIND:
        _encode_unicode_impl(writer, PyUnicode_2BYTE_DATA(data), length)
    elif kind == PyUnicode_4BYTE_KIND:
        _encode_unicode_impl(writer, PyUnicode_4BYTE_DATA(data), length)
    else:
        pass  # impossible

    return True


cdef boolean _encode_nested_key(WriterRef writer, object data) except False:
    cdef const char *string
    cdef char c
    cdef Py_ssize_t index, length

    cdef WriterReallocatable sub_writer = WriterReallocatable(
        Writer(_WriterReallocatable_reserve, _WriterReallocatable_append_c, _WriterReallocatable_append_s),
        0, 0, NULL,
    )
    try:
        _encode(sub_writer.base, data)

        length = sub_writer.position
        string = <char*> sub_writer.obj

        writer.reserve(writer, 2 + length)
        writer.append_c(writer, <char> b'"')
        for index in range(length):
            c = string[index]
            if c not in b'\\"':
                writer.append_c(writer, c)
            elif c == b'\\':
                writer.append_s(writer, b'\\\\', 2)
            else:
                writer.append_s(writer, b'\\u0022', 6)
        writer.append_c(writer, <char> b'"')
    finally:
        if sub_writer.obj is not NULL:
            ObjectFree(sub_writer.obj)

    return True


cdef boolean _append_ascii(WriterRef writer, object data) except False:
    cdef Py_buffer view
    cdef const char *buf

    if PyUnicode_Check(data):
        PyUnicode_READY(data)
        if not PyUnicode_IS_ASCII(data):
            raise TypeError('Expected ASCII data')
        writer.append_s(writer, <const char*> PyUnicode_1BYTE_DATA(data), PyUnicode_GET_LENGTH(data))
    else:
        PyObject_GetBuffer(data, &view, PyBUF_CONTIG_RO)
        try:
            buf = <const char*> view.buf
            for index in range(view.len):
                c = buf[index]
                if c & ~0x7f:
                    raise TypeError('Expected ASCII data')

            writer.append_s(writer, buf, view.len)
        finally:
            PyBuffer_Release(&view)

    return True


cdef boolean _encode_sequence(WriterRef writer, object data) except False:
    cdef boolean first
    cdef object value

    writer.append_c(writer, <char> b'[')
    first = True
    for value in data:
        if not first:
            writer.append_c(writer, <char> b',')
        else:
            first = False
        _encode(writer, value)
    writer.append_c(writer, <char> b']')

    return True


cdef boolean _encode_mapping(WriterRef writer, object data) except False:
    cdef boolean first
    cdef object key, value

    writer.append_c(writer, <char> b'{')
    first = True
    for key in data:
        if not first:
            writer.append_c(writer, <char> b',')
        else:
            first = False
        value = data[key]

        if PyUnicode_Check(key):
            _encode_unicode(writer, key, ENC_TYPE_UNICODE)
        else:
            _encode_nested_key(writer, key)

        writer.append_c(writer, <char> b':')
        _encode(writer, value)
    writer.append_c(writer, <char> b'}')

    return True


cdef boolean _encode_constant(WriterRef writer, object data, EncType enc_type) except False:
    cdef const char *string
    cdef Py_ssize_t length
    
    if data is True:
        string = b'true'
        length = 4
    elif data is False:
        string = b'false'
        length = 5
    else:
        string = b'null'
        length = 4

    writer.append_s(writer, string, length)
    return True


cdef boolean _encode_bytes(WriterRef writer, object data, EncType enc_type) except False:
    cdef unicode_data = data.decode('UTF-8', 'replace')
    _encode_unicode(writer, unicode_data, ENC_TYPE_UNICODE)
    return True


cdef boolean _encode_datetime(WriterRef writer, object data, EncType enc_type) except False:
    cdef const char *string
    cdef Py_ssize_t length
    cdef object stringified

    stringified = data.isoformat()
    string = PyUnicode_AsUTF8AndSize(stringified, &length)

    writer.reserve(writer, 2 + length)
    writer.append_c(writer, <char> b'"')
    writer.append_s(writer, string, length)
    writer.append_c(writer, <char> b'"')

    return True


cdef boolean _encode_numeric(WriterRef writer, object data, EncType enc_type) except False:
    cdef object formatter_string
    cdef object formatted_data
    cdef const char *string
    cdef Py_ssize_t length
    cdef int classification

    if enc_type == ENC_TYPE_LONG:
        formatter_string = '%d'
    elif enc_type == ENC_TYPE_DECIMAL:
        formatter_string = '%s'
    else:
        value = PyFloat_AsDouble(data)
        classification = fpclassify(value)
        if classification != FP_NORMAL:
            if classification == FP_NAN:
                string = b'NaN'
                length = 3
            elif classification in (FP_SUBNORMAL, FP_ZERO):
                string = b'0'
                length = 1
            elif value > 0.0:
                string = b'Infinity'
                length = 8
            else:
                string = b'-Infinity'
                length = 9

            writer.append_s(writer, string, length)
            return True
        else:
            formatter_string = '%.6e'

    formatted_data = (formatter_string % data)
    string = PyUnicode_AsUTF8AndSize(formatted_data, &length)
    writer.append_s(writer, string, length)

    return True


cdef boolean _encode_recursive(WriterRef writer, object data, EncType enc_type) except False:
    cdef object to_json_callback
    cdef object to_json = TO_JSON
    cdef boolean (*encoder)(WriterRef writer, object data) except False

    Py_EnterRecursiveCall(' while encoding nested JSON5 object')
    try:
        if to_json:
            to_json = getattr(data, to_json, None)
            if to_json is not None:
                if callable(to_json):
                    to_json = to_json()
                _append_ascii(writer, to_json)
                return True

        if enc_type == ENC_TYPE_SEQUENCE:
            encoder = _encode_sequence
        elif enc_type == ENC_TYPE_MAPPING:
            encoder = _encode_mapping
        elif expect(True, False):
            _raise_unstringifiable(data)

        encoder(writer, data)
        return True
    finally:
        Py_LeaveRecursiveCall()


cdef boolean _encode(WriterRef writer, object data) except False:
    cdef boolean (*encoder)(WriterRef, object, EncType) except False
    cdef EncType enc_type

    if data is None:
        enc_type = ENC_TYPE_NONE
    elif PyUnicode_Check(data):
        enc_type = ENC_TYPE_UNICODE
    elif PyBool_Check(data):
        enc_type = ENC_TYPE_BOOL
    elif PyBytes_Check(data):
        enc_type = ENC_TYPE_BYTES
    elif PyLong_Check(data):
        enc_type = ENC_TYPE_LONG
    elif PyFloat_Check(data):
        enc_type = ENC_TYPE_FLOAT
    elif obj_has_iter(data):
        if isinstance(data, Mapping):
            enc_type = ENC_TYPE_MAPPING
        else:
            enc_type = ENC_TYPE_SEQUENCE
    elif isinstance(data, Decimal):
        enc_type = ENC_TYPE_DECIMAL
    elif isinstance(data, DATETIME_CLASSES):
        enc_type = ENC_TYPE_DATETIME
    elif data == None:
        enc_type = ENC_TYPE_NONE
    else:
        enc_type = ENC_TYPE_UNKNOWN

    if enc_type in (ENC_TYPE_NONE, ENC_TYPE_BOOL):
        encoder = _encode_constant
    elif enc_type == ENC_TYPE_UNICODE:
        encoder = _encode_unicode
    elif enc_type == ENC_TYPE_BYTES:
        encoder = _encode_bytes
    elif enc_type in (ENC_TYPE_LONG, ENC_TYPE_DECIMAL, ENC_TYPE_FLOAT):
        encoder = _encode_numeric
    elif enc_type == ENC_TYPE_DATETIME:
        encoder = _encode_datetime
    else:
        encoder = _encode_recursive

    encoder(writer, data, enc_type)

    return True
