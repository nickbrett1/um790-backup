      static_hit=0
      for e in "${STATIC_SQLITE[@]}"; do
        # The DIRECTORY is compared literally and only the basename is globbed.
        # `[[ $f == $e ]]` with the whole path would let the pattern's `*` cross a
        # `/` - bash globbing inside [[ ]] has no FNM_PATHNAME - so
        # .../backups/mailroom_pre_*/anything/live.db would match and be exempted
        # from the drift scan while restic copied a live database. Splitting at the
        # last slash keeps the pattern anchored to one directory.
        if [[ ${f%/*} == "${e%/*}" && ${f##*/} == "${e##*/}" ]]; then
          static_hit=1
        fi
      done
