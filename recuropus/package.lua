return {
  name = "recuropus",
  version = "0.0.1",
  private = true,
  files = {
    "*.lua",
    "opusenc*",
    "ffmpeg*",
  },
  dependencies = {
    "luvit/luvit",
    "luvit/require",
    "luvit/core",
    "luvit/path",
    "luvit/fs",
    "luvit/childprocess"
  }
}