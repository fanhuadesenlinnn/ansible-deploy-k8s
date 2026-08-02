#!/usr/bin/env bash
# 只验证菜单导航和错误恢复，不连接节点、不构建镜像，也不修改本机环境。
set -euo pipefail

test_repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ansible-k8s-menu-test.XXXXXX")
trap 'rm -rf -- "${test_temp_dir}"' EXIT INT TERM

test_run_menu() {
  local test_name=$1
  local test_input=$2
  local output_file="${test_temp_dir}/${test_name}.out"

  printf '%b' "${test_input}" | "${test_repo_root}/ops.sh" >"${output_file}" 2>&1
  printf '%s\n' "${output_file}"
}

test_assert_contains() {
  local output_file=$1
  local expected_text=$2
  local output_text

  output_text=$(<"${output_file}")
  case "${output_text}" in
    *"${expected_text}"*) ;;
    *)
      printf '[失败] 输出中缺少：%s\n' "${expected_text}" >&2
      printf '%s\n' "${output_text}" >&2
      exit 1
      ;;
  esac
}

test_assert_menu_count() {
  local output_file=$1
  local expected_count=$2
  local actual_count

  actual_count=$(awk '/^ansible-deploy-k8s 操作菜单$/ {count++} END {print count + 0}' "${output_file}")
  if [[ ${actual_count} -ne ${expected_count} ]]; then
    printf '[失败] 预期主菜单出现 %s 次，实际为 %s 次。\n' "${expected_count}" "${actual_count}" >&2
    exit 1
  fi
}

invalid_output=$(test_run_menu invalid 'x\n0\n')
test_assert_contains "${invalid_output}" "无效的菜单选项：x"
test_assert_menu_count "${invalid_output}" 2

back_output=$(test_run_menu back '1\nb\n0\n')
test_assert_contains "${back_output}" "已返回主菜单"
test_assert_menu_count "${back_output}" 2

submenu_output=$(test_run_menu submenu '2\n\n\nb\n0\n')
test_assert_contains "${submenu_output}" "检查环境与连接"
test_assert_contains "${submenu_output}" "已返回主菜单"
test_assert_menu_count "${submenu_output}" 2

quit_output=$(test_run_menu quit '3\nq\n')
test_assert_contains "${quit_output}" "离线包操作"
test_assert_menu_count "${quit_output}" 1

nested_invalid_output=$(test_run_menu nested-invalid '3\nx\nq\n')
test_assert_contains "${nested_invalid_output}" "无效选择，请输入菜单编号"
test_assert_menu_count "${nested_invalid_output}" 1

printf '[通过] 交互菜单导航、返回、退出和错误恢复测试通过。\n'
