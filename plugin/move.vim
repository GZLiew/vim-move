" =============================================================================
" File: plugin/move.vim
" Description: Move lines and selections up and even down.
" Author: Matthias Vogelgesang <github.com/matze>
" =============================================================================

if exists('g:loaded_move') || &compatible
    finish
endif

let g:loaded_move = 1

if !exists('g:move_map_keys')
    let g:move_map_keys = 1
endif

if !exists('g:move_key_modifier')
    let g:move_key_modifier = 'A'
endif

if !exists('g:move_key_modifier_visualmode')
    let g:move_key_modifier_visualmode = 'A'
endif

" Only remap option keys if the user specifies (see pull request #71)
if !exists('g:move_normal_option')
    let g:move_normal_option = 0
endif

if !exists('g:move_auto_indent')
    let g:move_auto_indent = 1
endif

if !exists('g:move_past_end_of_line')
    let g:move_past_end_of_line = 1
endif

if !exists('g:move_undo_join')
    let g:move_undo_join = 1
endif

if !exists('g:move_undo_join_same_dir_only')
    let g:move_undo_join_same_dir_only = 1
endif

function s:UndoJoin(dir)
    " Check changedtick to see if there were no other changes since our last
    " operation. Dending on settings we may also require the same dir of move.
    let l:last = get(b:, 'move_last', { 'changedtick': -1, 'dir': v:null })
    let l:no_changes = l:last.changedtick == b:changedtick
    let l:dir_ok = g:move_undo_join_same_dir_only == 0 || l:last.dir == a:dir
    if l:no_changes && l:dir_ok
        silent! undojoin
    endif
endfunction

function s:SaveMoveInfo(dir)
    " Save changedtick/dir to check it in the next move operation.
    let b:move_last = { 'changedtick': b:changedtick, 'dir': a:dir }
endfunction

"
" Move and possibly reindent the given lines.
" Goes down if (distance > 0) and up if (distance < 0).
" Places the cursor at last moved line.
"
function s:MoveVertically(first, last, distance)
    if !&modifiable || a:distance == 0
        return
    endif

    let l:first = line(a:first)
    let l:last  = line(a:last)

    " Compute the destination line. Instead of simply incrementing the line
    " number, we move the cursor with `J` and `K`. This ensures that the
    " destination line is in bounds and it also goes past closed folds.
    let l:old_pos = getcurpos()
    if a:distance < 0
        call cursor(l:first, 1)
        execute 'normal!' (-a:distance).'K'
        let l:after = line('.') - 1
    else
        call cursor(l:last, 1)
        execute 'normal!' a:distance.'J'
        let l:after = (foldclosedend('.') == -1 ? line('.') : foldclosedend('.'))
    endif

    " Restoring the cursor position might seem redundant because of the
    " upcoming :move. However, it prevents a weird issue where undoing a move
    " across a folded section causes it to unfold.
    call setpos('.', l:old_pos)

    if g:move_undo_join
        call s:UndoJoin(a:distance < 0 ? 'up' : 'down')
    endif

    " After this :move the '[ and '] marks will point to first and last moved
    " line and the cursor will be placed at the last line.
    execute l:first ',' l:last 'move' l:after

    if g:move_auto_indent
        " To preserve the relative indentation between lines we only use '=='
        " on the first line, to figure out by how much we need to reindent.
        " This heuristic assumes that the indentation level of the first line
        " is less than or equal to the indentation level of the other lines.
        " I don't think there is an easy way to reindent if that is not true.
        let l:first = line("'[")
        let l:last  = line("']")

        call cursor(l:first, 1)
        let l:old_indent = indent('.')
        normal! ==
        let l:new_indent = indent('.')

        if l:first < l:last && l:old_indent != l:new_indent
            let l:op = (l:old_indent < l:new_indent
                        \  ? repeat('>', l:new_indent - l:old_indent)
                        \  : repeat('<', l:old_indent - l:new_indent))
            let l:old_sw = &shiftwidth
            let &shiftwidth = 1
            execute l:first+1 ',' l:last l:op
            let &shiftwidth = l:old_sw
        endif

        call cursor(l:first, 1)
        normal! 0m[
        call cursor(l:last, 1)
        normal! $m]
    endif

    if g:move_undo_join
        call s:SaveMoveInfo(a:distance < 0 ? 'up' : 'down')
    endif
endfunction

"
" In normal mode, move the current line vertically.
" The cursor stays pointing at the same character as before.
"
function s:MoveLineVertically(distance)
    let l:old_col    = col('.')
    normal! ^
    let l:old_indent = col('.')

    call s:MoveVertically('.', '.', a:distance)

    normal! ^
    let l:new_indent = col('.')
    call cursor(line('.'), max([1, l:old_col - l:old_indent + l:new_indent]))
endfunction

"
" In visual mode, move the selected lines vertically.
" Maintains the current selection, albeit not exactly if auto_indent is on.
"
function s:MoveBlockVertically(distance)
    call s:MoveVertically("'<", "'>", a:distance)
    normal! gv
endfunction


"
" If in normal mode, moves the character under the cursor.
" If in blockwise visual mode, moves the selected rectangular area.
" Goes right if (distance > 0) and left if (distance < 0).
" Returns whether an edit was made.
"
function s:MoveHorizontally(corner_start, corner_end, distance)
    if !&modifiable || a:distance == 0
        return 0
    endif

    let l:cols = [col(a:corner_start), col(a:corner_end)]
    let l:first = min(l:cols)
    let l:last  = max(l:cols)
    let l:width = l:last - l:first + 1

    let l:before = max([1, l:first + a:distance])
    if a:distance > 0 && !g:move_past_end_of_line
        let l:lines = getline(a:corner_start, a:corner_end)
        let l:shortest = min(map(l:lines, 'strwidth(v:val)'))
        if l:last < l:shortest
            let l:before = min([l:before, l:shortest - l:width + 1])
        else
            let l:before = l:first
        endif
    endif

    if l:first == l:before
        " Don't add an empty change to the undo stack
        return 0
    endif

    if g:move_undo_join
        call s:UndoJoin(a:distance < 0 ? 'left' : 'right')
    endif

    let l:old_default_register = @"
    normal! x

    let l:old_virtualedit = &virtualedit
    if l:before >= col('$')
        let &virtualedit = 'all'
    else
        " Because of a Vim <= 8.2 bug, we must disable virtualedit in this case.
        " See https://github.com/vim/vim/pull/6430
        let &virtualedit = ''
    endif

    call cursor(line('.'), l:before)
    normal! P

    let &virtualedit = l:old_virtualedit
    let @" = l:old_default_register

    if g:move_undo_join
        call s:SaveMoveInfo(a:distance < 0 ? 'left' : 'right')
    endif

    return 1
endfunction

"
" In normal mode, move the character under the cursor horizontally
"
function s:MoveCharHorizontally(distance)
    call s:MoveHorizontally('.', '.', a:distance)
endfunction

"
" In visual mode, switch to blockwise mode then move the selected rectangular
" area horizontally. Maintains the selection although the cursor may be moved
" to the bottom right corner if it wasn't already there.
"
function s:MoveBlockHorizontally(distance)
    execute "normal! g`<\<C-v>g`>"
    if s:MoveHorizontally("'<", "'>", a:distance)
        execute "normal! g`[\<C-v>g`]"
    endif
endfunction


function s:HalfPageSize()
    return winheight('.') / 2
endfunction

" Equivalent keys for <A-KEY> on macOS (see issue #49)
let s:mac_map_keys = {'K': '˚', 'J': '∆', 'H': '˙', 'L': '¬'}

function s:MoveKey(key)
    " If on macOS, use the equivalent key for <A-KEY>
    if g:move_normal_option && g:move_key_modifier_visualmode ==? 'A'
        return s:mac_map_keys[a:key]
    endif
    return '<' . g:move_key_modifier . '-' . a:key . '>'
endfunction

function s:VisualMoveKey(key)
    if g:move_normal_option && g:move_key_modifier_visualmode ==? 'A'
        return s:mac_map_keys[a:key]
    endif
    return '<' . g:move_key_modifier_visualmode . '-' . a:key . '>'
endfunction

" Note: An older version of this program used callbacks with the "range"
" attribute to support being called with a selection range as a parameter.
" However, that had some problems: we would get E16 errors if the user tried
" to perform an out-of bounds move and the computations that used col() would
" also return the wrong results. Because of this, we have switched everything
" to using <C-u>.

vnoremap <silent> <Plug>MoveBlockDown           :<C-u> silent call <SID>MoveBlockVertically( v:count1)<CR>
vnoremap <silent> <Plug>MoveBlockUp             :<C-u> silent call <SID>MoveBlockVertically(-v:count1)<CR>
vnoremap <silent> <Plug>MoveBlockHalfPageDown   :<C-u> silent call <SID>MoveBlockVertically( v:count1 * <SID>HalfPageSize())<CR>
vnoremap <silent> <Plug>MoveBlockHalfPageUp     :<C-u> silent call <SID>MoveBlockVertically(-v:count1 * <SID>HalfPageSize())<CR>
vnoremap <silent> <Plug>MoveBlockRight          :<C-u> silent call <SID>MoveBlockHorizontally( v:count1)<CR>
vnoremap <silent> <Plug>MoveBlockLeft           :<C-u> silent call <SID>MoveBlockHorizontally(-v:count1)<CR>

nnoremap <silent> <Plug>MoveLineDown            :<C-u> silent call <SID>MoveLineVertically( v:count1)<CR>
nnoremap <silent> <Plug>MoveLineUp              :<C-u> silent call <SID>MoveLineVertically(-v:count1)<CR>
nnoremap <silent> <Plug>MoveLineHalfPageDown    :<C-u> silent call <SID>MoveLineVertically( v:count1 * <SID>HalfPageSize())<CR>
nnoremap <silent> <Plug>MoveLineHalfPageUp      :<C-u> silent call <SID>MoveLineVertically(-v:count1 * <SID>HalfPageSize())<CR>
nnoremap <silent> <Plug>MoveCharRight           :<C-u> silent call <SID>MoveCharHorizontally( v:count1)<CR>
nnoremap <silent> <Plug>MoveCharLeft            :<C-u> silent call <SID>MoveCharHorizontally(-v:count1)<CR>


if g:move_map_keys
    execute 'vmap' s:VisualMoveKey('J') '<Plug>MoveBlockDown'
    execute 'vmap' s:VisualMoveKey('K') '<Plug>MoveBlockUp'
    execute 'vmap' s:VisualMoveKey('H') '<Plug>MoveBlockLeft'
    execute 'vmap' s:VisualMoveKey('L') '<Plug>MoveBlockRight'

    execute 'nmap' s:MoveKey('J') '<Plug>MoveLineDown'
    execute 'nmap' s:MoveKey('K') '<Plug>MoveLineUp'
    execute 'nmap' s:MoveKey('H') '<Plug>MoveCharLeft'
    execute 'nmap' s:MoveKey('L') '<Plug>MoveCharRight'
endif
