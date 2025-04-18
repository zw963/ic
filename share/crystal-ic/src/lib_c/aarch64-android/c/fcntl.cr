require "./sys/types"
require "./sys/stat"
require "./unistd"

lib LibC
  F_GETFD    =         1
  F_SETFD    =         2
  F_GETFL    =         3
  F_SETFL    =         4
  FD_CLOEXEC =         1
  O_CLOEXEC  = 0o2000000
  O_CREAT    =     0o100
  O_EXCL     =    0o0200
  O_NOFOLLOW =  0o100000
  O_TRUNC    =    0o1000
  O_APPEND   =    0o2000
  O_NONBLOCK =    0o4000
  O_SYNC     = 0o4010000
  O_RDONLY   =       0o0
  O_RDWR     =       0o2
  O_WRONLY   =       0o1
  AT_FDCWD   =      -100

  fun fcntl(__fd : Int, __cmd : Int, ...) : Int
  fun open(__path : Char*, __flags : Int, ...) : Int
end
