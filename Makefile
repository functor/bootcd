ETAGS=etags

tags:
	find . -type f -a '!' '(' -name '*.x86' -o -name '*.x86_64' ')' | grep -v '/\.svn/' | xargs $(ETAGS)

.PHONY: tags
