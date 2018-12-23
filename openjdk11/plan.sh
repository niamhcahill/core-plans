pkg_origin=core
pkg_maintainer="The Habitat Maintainers <humans@habitat.sh>"
pkg_name=openjdk11
pkg_version=11.0.1
pkg_source=https://download.java.net/java/GA/jdk11/13/GPL/openjdk-${pkg_version}_linux-x64_bin.tar.gz
pkg_shasum=7a6bb980b9c91c478421f865087ad2d69086a0583aeeb9e69204785e8e97dcfd
pkg_filename=openjdk-${pkg_version}_linux-x64_bin.tar.gz
pkg_dirname="jdk-${pkg_version}"
pkg_license=("GPL-2.0")
pkg_description=('Oracle Java Runtime Environment. This package is made available to you to allow you to run your applications as provided in and subject to the terms of the Oracle Binary Code License Agreement for the Java SE Platform Products and JavaFX, found at http://www.oracle.com/technetwork/java/javase/terms/license/index.html')
pkg_upstream_url=https://openjdk.java.net/
pkg_deps=(core/glibc core/gcc-libs core/xlib core/libxi core/libxext core/libxrender core/libxtst core/zlib)
pkg_build_deps=(core/patchelf core/rsync)
pkg_bin_dirs=(bin)
pkg_lib_dirs=(lib)
pkg_include_dirs=(include)

source_dir=$HAB_CACHE_SRC_PATH/${pkg_dirname}

do_setup_environment() {
 set_runtime_env JAVA_HOME "$pkg_prefix"
}

do_build() {
  return 0
}

do_install() {
  pushd ${pkg_prefix}
  rsync -avz ${source_dir}/ .

  export LD_RUN_PATH="${LD_RUN_PATH}:${pkg_prefix}/lib/jli:${pkg_prefix}/lib/server:${pkg_prefix}/lib"

  build_line "Setting interpreter for all executables to '$(pkg_path_for glibc)/lib/ld-linux-x86-64.so.2'"
  build_line "Setting rpath for all libraries to '$LD_RUN_PATH'"

  find "$pkg_prefix"/bin -type f -executable \
    -exec sh -c 'file -i "$1" | grep -q "x-executable; charset=binary"' _ {} \; \
    -exec patchelf --interpreter "$(pkg_path_for glibc)/lib/ld-linux-x86-64.so.2" --set-rpath "${LD_RUN_PATH}" {} \;

  find "$pkg_prefix/lib" -type f -name "*.so" \
    -exec patchelf --set-rpath "${LD_RUN_PATH}" {} \;

  popd
}

do_strip() {
  return 0
}
