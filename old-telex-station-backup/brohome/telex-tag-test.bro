event bro_init() {
      telex_init();
      print fmt("Test tag key: %s", telex_tag_get_key("\x1e\x25\xc2\x56\xb4\x5d\x93\x99\x62\xf8\xd2\x21\x5c\x76\xb4\xbc\x44\xaa\xf9\x58\xaf\xd5\xe0\xaa\x31\xe8\xeb\x1f"));
      print fmt("Test tag with a bit flipped key: %s", telex_tag_get_key("\x0e\x25\xc2\x56\xb4\x5d\x93\x99\x62\xf8\xd2\x21\x5c\x76\xb4\xbc\x44\xaa\xf9\x58\xaf\xd5\xe0\xaa\x31\xe8\xeb\x1f"));
      print fmt("too-short string key: %s", telex_tag_get_key("hello"));
}

event bro_done() {
      telex_shutdown();
}