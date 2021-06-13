#!/bin/sh

set -eux

. "$( cd "$(dirname "$0")" ; pwd -P )/../../ghcup_env"

mkdir -p "${TMPDIR}"

if [ $ARCH = 'ARM64' ] ; then
	curl -sSfL https://downloads.haskell.org/~ghcup/0.1.15.1/aarch64-apple-darwin-ghcup-0.1.15.1 > ./ghcup-bin
	chmod +x ghcup-bin
else
	curl -sSfL https://downloads.haskell.org/~ghcup/x86_64-apple-darwin-ghcup > ./ghcup-bin
	chmod +x ghcup-bin
	./ghcup-bin upgrade -i -f
fi

./ghcup-bin install ${GHC_VERSION}
./ghcup-bin set ${GHC_VERSION}
./ghcup-bin install-cabal ${CABAL_VERSION}

exit 0
