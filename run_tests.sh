#!/bin/sh
# Runs lera-plugins Lua tests against a resolved Lera checkout's LuaJIT.
set -eu

invocation_dir=$(pwd -P)
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P) || {
  printf '%s\n' "cannot resolve lera-plugins checkout" >&2
  exit 1
}
cd "$script_dir"

resolve_dir() {
  CDPATH= cd "$1" 2>/dev/null && pwd -P
}

if [ -n "${LERA_ROOT:-}" ]; then
  case "$LERA_ROOT" in
    /*) lera_candidate=$LERA_ROOT ;;
    *) lera_candidate=$invocation_dir/$LERA_ROOT ;;
  esac
else
  git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
    printf '%s\n' "cannot resolve lera-plugins Git common directory" >&2
    exit 1
  }
  case "$git_common_dir" in
    /*) ;;
    *) git_common_dir=$script_dir/$git_common_dir ;;
  esac
  git_common_dir=$(resolve_dir "$git_common_dir") || {
    printf '%s\n' "invalid lera-plugins Git common directory" >&2
    exit 1
  }
  if [ "$(basename "$git_common_dir")" != ".git" ]; then
    printf '%s\n' "unsupported lera-plugins Git common directory" >&2
    exit 1
  fi
  canonical_root=$(dirname "$git_common_dir")
  lera_candidate=$canonical_root/../lera
fi

lera_root=$(resolve_dir "$lera_candidate") || {
  printf 'invalid LERA_ROOT: %s\n' "$lera_candidate" >&2
  exit 1
}
case "$lera_root" in
  *";"*|*"?"*)
    printf 'unsupported LERA_ROOT for Lua module paths: %s\n' "$lera_root" >&2
    exit 1
    ;;
esac

luajit=$lera_root/external/luajit/src/luajit
wm_module=$lera_root/scripts/default/wm.lua
[ -x "$luajit" ] || { printf 'missing %s - build lera first\n' "$luajit" >&2; exit 1; }
[ -r "$wm_module" ] || { printf 'missing %s - cannot load wm\n' "$wm_module" >&2; exit 1; }

LERA_ROOT=$lera_root "$luajit" tests/chat_monitor_test.lua
LERA_ROOT=$lera_root "$luajit" tests/chat_recording_test.lua
LERA_ROOT=$lera_root "$luajit" tests/push_notify_test.lua
LERA_ROOT=$lera_root "$luajit" tests/combat_notify_test.lua
LERA_ROOT=$lera_root "$luajit" tests/deadmans_test.lua
LERA_ROOT=$lera_root "$luajit" tests/kill_trigger_test.lua
LERA_ROOT=$lera_root "$luajit" tests/old_push_producers_test.lua
LERA_ROOT=$lera_root "$luajit" tests/mxp_links_test.lua
LERA_ROOT=$lera_root "$luajit" tests/gmcp_state_test.lua
LERA_ROOT=$lera_root "$luajit" tests/roominfo_test.lua
LERA_ROOT=$lera_root "$luajit" tests/speedwalk_test.lua
LERA_ROOT=$lera_root "$luajit" tests/minimap_test.lua
LERA_ROOT=$lera_root "$luajit" tests/minimap_next_test.lua
LERA_ROOT=$lera_root "$luajit" tests/mapper_test.lua
LERA_ROOT=$lera_root "$luajit" tests/mapview_test.lua
LERA_ROOT=$lera_root "$luajit" tests/autostepper_test.lua
LERA_ROOT=$lera_root "$luajit" tests/autostepper_arrival_test.lua
LERA_ROOT=$lera_root "$luajit" tests/autostepper_map_test.lua
LERA_ROOT=$lera_root "$luajit" tests/autostepper_explore_test.lua
LERA_ROOT=$lera_root "$luajit" tests/autostepper_chaossea_test.lua
LERA_ROOT=$lera_root "$luajit" tests/stats_window_test.lua
LERA_ROOT=$lera_root "$luajit" tests/mudstatus_test.lua
LERA_ROOT=$lera_root "$luajit" tests/mercenary_gmcp_test.lua
LERA_ROOT=$lera_root "$luajit" tests/mercenary_state_test.lua
LERA_ROOT=$lera_root "$luajit" tests/mercenary_command_test.lua
LERA_ROOT=$lera_root "$luajit" tests/mercenary_init_test.lua
LERA_ROOT=$lera_root "$luajit" tests/crafting_refinery_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_settlement_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_grid_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_map_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_fleet_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_roster_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_trade_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_city_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_livestock_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_voyage_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_kingdom_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_gmcp_war_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_census_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_combat_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_pagelib_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_window_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_page_menu_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_popups_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_maplib_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_tiles_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_pathfinding_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_popup_map_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_popup_sea_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_popup_cityplan_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_popup_war_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_popup_dispatch_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_pages1_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_pages2_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_pages3_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_pages4_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_livestock_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_herd_forecast_test.lua
LERA_ROOT=$lera_root "$luajit" tests/guild_viking_herd_replace_test.lua
LERA_ROOT=$lera_root "$luajit" tests/wizard_complete_test.lua
LERA_ROOT=$lera_root "$luajit" tests/wizard_table_test.lua
LERA_ROOT=$lera_root "$luajit" tests/wizard_protocol_test.lua
LERA_ROOT=$lera_root "$luajit" tests/wizard_init_test.lua
LERA_ROOT=$lera_root "$luajit" tests/wizard_pane_test.lua
LERA_ROOT=$lera_root "$luajit" tests/wizard_lpc_test.lua
LERA_ROOT=$lera_root "$luajit" tests/wizard_ferry_test.lua
LERA_ROOT=$lera_root "$luajit" tests/player_stats_test.lua
