add_executable(
  bssl

  tool.cc
  server.cc # the TLS server
)

target_compile_options(bssl PUBLIC -DINTERNAL_TOOL)

function(build_benchmark target_name install_path)
  add_executable(
          ${target_name}
          speed.cc
  )
endfunction()
