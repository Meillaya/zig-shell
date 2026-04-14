echo fixture-start
export DEMO_NAME=zig
printf 'a\nb\n' | grep b > demo-out.txt
echo "hello $DEMO_NAME"
source ./tests/fixtures/source-env.zsh
echo "sourced:$FROM_SOURCE"
