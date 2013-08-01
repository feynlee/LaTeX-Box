" LaTeX Box latexmk functions

" Options and variables {{{

if !exists('g:LatexBox_latexmk_options')
	let g:LatexBox_latexmk_options = ''
endif
if !exists('g:LatexBox_latexmk_async')
	let g:LatexBox_latexmk_async = 0
endif
if !exists('g:LatexBox_latexmk_preview_continuously')
	let g:LatexBox_latexmk_preview_continuously = 0
endif
if !exists('g:LatexBox_output_type')
	let g:LatexBox_output_type = 'pdf'
endif
if !exists('g:LatexBox_autojump')
	let g:LatexBox_autojump = 0
endif
if ! exists('g:LatexBox_quickfix')
	let g:LatexBox_quickfix = 1
endif

" }}}

" Process ID management (used for asynchronous and continuous mode) {{{

" dictionary of latexmk PID's (basename: pid)
if !exists('g:latexmk_running_pids')
	let g:latexmk_running_pids = {}
endif

" Set PID {{{
function! s:LatexmkSetPID(basename, pid)
	let g:latexmk_running_pids[a:basename] = a:pid
endfunction
" }}}

" kill_latexmk_process {{{
function! s:kill_latexmk_process(pid)
	if has('win32')
		silent execute '!taskkill /PID ' . a:pid . ' /T /F'
	else
		if g:LatexBox_latexmk_async
			" vim-server mode
			let pids = []
			let tmpfile = tempname()
			silent execute '!ps x -o pgid,pid > ' . tmpfile
			for line in readfile(tmpfile)
				let new_pid = matchstr(line, '^\s*' . a:pid . '\s\+\zs\d\+\ze')
				if !empty(new_pid)
					call add(pids, new_pid)
				endif
			endfor
			call delete(tmpfile)
			if !empty(pids)
				silent execute '!kill ' . join(pids)
			endif
		else
			" single background process
			silent execute '!kill ' . a:pid
		endif
	endif
	if !has('gui_running')
		redraw!
	endif
endfunction
" }}}

" kill_all_latexmk_processes {{{
function! s:kill_all_latexmk_processes()
	for pid in values(g:latexmk_running_pids)
		call s:kill_latexmk_process(pid)
	endfor
endfunction
" }}}

" }}}

" Setup for vim-server {{{
function! s:SIDWrap(func)
	if !exists('s:SID')
		let s:SID = matchstr(expand('<sfile>'), '\zs<SNR>\d\+_\ze.*$')
	endif
	return s:SID . a:func
endfunction

function! s:LatexmkCallback(basename, status)
	" Only remove the pid if not in continuous mode
	if !g:LatexBox_latexmk_preview_continuously
		call remove(g:latexmk_running_pids, a:basename)
		call LatexBox_LatexErrors(a:status, a:basename)
	endif
endfunction

function! s:setup_vim_server()
	if !exists('g:vim_program')

		" attempt autodetection of vim executable
		let g:vim_program = ''
		if has('win32')
			" Just drop through to the default for windows
		else
			if match(&shell, '/\(bash\|zsh\)$') >= 0
				let ppid = '$PPID'
			else
				let ppid = '$$'
			endif

			let tmpfile = tempname()
			silent execute '!ps -o command= -p ' . ppid . ' > ' . tmpfile
			for line in readfile(tmpfile)
				let line = matchstr(line, '^\S\+\>')
				if !empty(line) && executable(line)
					let g:vim_program = line . ' -g'
					break
				endif
			endfor
			call delete(tmpfile)
		endif

		if empty(g:vim_program)
			if has('gui_macvim')
				let g:vim_program
						\ = '/Applications/MacVim.app/Contents/MacOS/Vim -g'
			else
				let g:vim_program = v:progname
			endif
		endif
	endif
endfunction
" }}}

" Latexmk {{{

function! LatexBox_Latexmk(force)
	" Define often used names
	let basepath = LatexBox_GetTexBasename(1)
	let basename = fnamemodify(basepath, ':t')
	let texroot = shellescape(LatexBox_GetTexRoot())
	let mainfile = fnameescape(fnamemodify(LatexBox_GetMainTexFile(), ':t'))

	" Check if already running
	if has_key(g:latexmk_running_pids, basepath)
		echomsg "latexmk is already running for `" . basename . "'"
		return
	endif

	" Set wrap width in log file
	let max_print_line = 2000
	if has('win32')
		let env = 'set max_print_line=' . max_print_line . ' & '
	elseif match(&shell, '/tcsh$') >= 0
		let env = 'setenv max_print_line ' . max_print_line . '; '
	else
		let env = 'max_print_line=' . max_print_line
	endif

	" Set latexmk command with options
	if has('win32')
		" Make sure to switch drive as well as directory
		let cmd = 'cd /D ' . texroot . ' && '
	else
		let cmd = 'cd ' . texroot . ' && '
	endif
	let cmd .= env . ' latexmk'
	let cmd .= ' -' . g:LatexBox_output_type 
	let cmd .= ' -quiet '
	let cmd .= g:LatexBox_latexmk_options
	if a:force
		let cmd .= ' -g'
	endif
	if g:LatexBox_latexmk_preview_continuously
		let cmd .= ' -pvc'
	endif
	let cmd .= ' -e ' . shellescape('$pdflatex =~ s/ / -file-line-error /')
	let cmd .= ' -e ' . shellescape('$latex =~ s/ / -file-line-error /')
	let cmd .= ' ' . mainfile

	if g:LatexBox_latexmk_async
		" Check if VIM server exists
		if empty(v:servername)
			echoerr "cannot run latexmk in background without a VIM server"
			echoerr "set g:LatexBox_latexmk_async to 0 to change compiling mode"
			return
		endif

		" Start vim server if necessary
		call s:setup_vim_server()

		let setpidfunc = s:SIDWrap('LatexmkSetPID')
		let callbackfunc = s:SIDWrap('LatexmkCallback')
		if has('win32')
			let vim_program = substitute(g:vim_program,
						\ 'gvim\.exe$', 'vim.exe', '')

			" Define callback to set the pid
			let callsetpid = setpidfunc . '(''' . basepath . ''', %CMDPID%)'
			let vimsetpid = vim_program . ' --servername ' . v:servername
						\ . ' --remote-expr ' . shellescape(callsetpid)

			" Define callback after latexmk is finished
			let callback = callbackfunc . '(''' . basepath . ''', %LATEXERR%)'
			let vimcmd = vim_program . ' --servername ' . v:servername
						\ . ' --remote-expr ' . shellescape(callback)

			let asyncbat = tempname() . '.bat'
			call writefile(['setlocal',
						\ 'set T=%TEMP%\sthUnique.tmp',
						\ 'wmic process where (Name="WMIC.exe" AND CommandLine LIKE "%%%TIME%%%") '
						\ . 'get ParentProcessId /value | find "ParentProcessId" >%T%',
						\ 'set /P A=<%T%',
						\ 'set CMDPID=%A:~16% & del %T%',
						\ vimsetpid,
						\ cmd,
						\ 'set LATEXERR=%ERRORLEVEL%',
						\ vimcmd,
						\ 'endlocal'], asyncbat)

			" Define command
			let cmd = '!start /b ' . asyncbat . ' & del ' . asyncbat
		else
			" Define callback to set the pid
			let callsetpid = shellescape(setpidfunc).'"(\"'.basepath.'\",$$)"'
			let vimsetpid = g:vim_program . ' --servername ' . v:servername
			                        \ . ' --remote-expr ' . callsetpid

			" Define callback after latexmk is finished
			let callback = shellescape(callbackfunc).'"(\"'.basepath.'\",$?)"'
			let vimcmd = g:vim_program . ' --servername ' . v:servername
			                        \ . ' --remote-expr ' . callback

			" Define command
			" Here we escape '%' because it may be given as a user option through
			" g:LatexBox_latexmk_options, for instance with an options like
			" g:Latex..._options = "-pdflatex='pdflatex -synctex=1 \%O \%S'"
			let cmd = vimsetpid . ' ; ' . escape(cmd, '%') . ' ; ' . vimcmd
			let cmd = '! (' . cmd . ') >/dev/null &'
		endif

		echo 'Compiling to ' . g:LatexBox_output_type . '...'
		silent execute cmd
	else
		" Define command
		if has('win32')
			let cmd .= ' >nul'
		else
			let cmd .= ' >/dev/null'
		endif

		if g:LatexBox_latexmk_preview_continuously
			if has('win32')
				let cmd = '!start /b cmd /s /c "' . cmd . '"'
			else
				let cmd = '!' . cmd . ' &'
			endif
			silent execute cmd

			" Save PID in order to be able to kill the process when wanted.
			if has('win32')
				let tmpfile = tempname()
				let pidcmd = 'cmd /c "wmic process where '
							\ . '(CommandLine LIKE "latexmk\%'.mainfile.'\%") '
							\ . 'get ProcessId /value | find "ProcessId" '
							\ . '>'.tmpfile.' "'
				silent execute '! ' . pidcmd
				let pids = readfile(tmpfile)
				let pid = strpart(pids[0], 10)
				let g:latexmk_running_pids[basepath] = pid
			else
				let pid = substitute(system('pgrep -f ' . mainfile),'\D','','')
				let g:latexmk_running_pids[basepath] = pid
			endif
		else
			" Execute command
			echo 'Compiling to ' . g:LatexBox_output_type . '...'
			let cmd_output = system(cmd)

			" Check for errors
			call LatexBox_LatexErrors(v:shell_error)
			if v:shell_error > 0
				echomsg "Error (latexmk exited with status "
							\ . v:shell_error
							\ . ")."
			elseif match(cmd_output, 'Rule') > -1
				echomsg "Success!"
			else
				echomsg "No file change detected. Skipping."
			endif
		endif
	endif

	" Redraw screen if necessary
	if !has("gui_running")
		redraw!
	endif
endfunction
" }}}

" LatexmkClean {{{
function! LatexBox_LatexmkClean(cleanall)
	let basename = LatexBox_GetTexBasename(1)
	if has_key(g:latexmk_running_pids, basename)
		echomsg "don't clean when latexmk is running"
		return
	endif

	if has('win32')
		let cmd = 'cd /D ' . shellescape(LatexBox_GetTexRoot()) . ' & '
	else
		let cmd = 'cd ' . shellescape(LatexBox_GetTexRoot()) . ';'
	endif
	if a:cleanall
		let cmd .= 'latexmk -C '
	else
		let cmd .= 'latexmk -c '
	endif
	let cmd .= shellescape(LatexBox_GetMainTexFile())
	if has('win32')
		let cmd .= ' >nul'
	else
		let cmd .= ' >&/dev/null'
	endif

	call system(cmd)
	if !has('gui_running')
		redraw!
	endif

	echomsg "latexmk clean finished"
endfunction
" }}}

" LatexErrors {{{
function! LatexBox_LatexErrors(status, ...)
	if a:0 >= 1
		let log = a:1 . '.log'
	else
		let log = LatexBox_GetLogFile()
	endif

	cclose

	" set cwd to expand error file correctly
	let l:cwd = fnamemodify(getcwd(), ':p')
	execute 'lcd ' . LatexBox_GetTexRoot()
	try
		if g:LatexBox_autojump
			execute 'cfile ' . fnameescape(log)
		else
			execute 'cgetfile ' . fnameescape(log)
		endif
	finally
		" restore cwd
		execute 'lcd ' . l:cwd
	endtry

	" always open window if started by LatexErrors command
	if a:status < 0
		botright copen
	" otherwise only when an error/warning is detected
	elseif g:LatexBox_quickfix
		botright cw
		if g:LatexBox_quickfix==2
			wincmd p
		endif
	endif

endfunction
" }}}

" LatexmkStatus {{{
function! LatexBox_LatexmkStatus(detailed)

	if a:detailed
		if empty(g:latexmk_running_pids)
			echo "latexmk is not running"
		else
			let plist = ""
			for [basename, pid] in items(g:latexmk_running_pids)
				if !empty(plist)
					let plist .= '; '
				endif
				let plist .= fnamemodify(basename, ':t') . ':' . pid
			endfor
			echo "latexmk is running (" . plist . ")"
		endif
	else
		let basename = LatexBox_GetTexBasename(1)
		if has_key(g:latexmk_running_pids, basename)
			echo "latexmk is running"
		else
			echo "latexmk is not running"
		endif
	endif

endfunction
" }}}

" LatexmkStop {{{
function! LatexBox_LatexmkStop(silent)
	let basename = LatexBox_GetTexBasename(1)
	if has_key(g:latexmk_running_pids, basename)
		call s:kill_latexmk_process(g:latexmk_running_pids[basename])
		call remove(g:latexmk_running_pids, basename)
		if !a:silent
			echomsg "latexmk stopped for `" . fnamemodify(basename, ':t') . "'"
		endif
	else
		if !a:silent
			echoerr "latexmk is not running for `" . fnamemodify(basename, ':t') . "'"
		endif
	endif
endfunction
" }}}

" Commands {{{

command! -bang	Latexmk			call LatexBox_Latexmk(<q-bang> == "!")
command! -bang	LatexmkClean	call LatexBox_LatexmkClean(<q-bang> == "!")
command! -bang	LatexmkStatus	call LatexBox_LatexmkStatus(<q-bang> == "!")
command! LatexmkStop			call LatexBox_LatexmkStop(0)
command! LatexErrors			call LatexBox_LatexErrors(-1)

if g:LatexBox_latexmk_async || g:LatexBox_latexmk_preview_continuously
	autocmd BufUnload <buffer> 	call LatexBox_LatexmkStop(1)
	autocmd VimLeave * 			call <SID>kill_all_latexmk_processes()
endif

" }}}

" vim:fdm=marker:ff=unix:noet:ts=4:sw=4
