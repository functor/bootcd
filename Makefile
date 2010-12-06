ETAGS=etags

tags:
	find . -type f -a '!' '(' -name '*.x86' -o -name '*.x86_64' ')' | egrep -v '/\.(svn|git)/' | xargs $(ETAGS)

.PHONY: tags
