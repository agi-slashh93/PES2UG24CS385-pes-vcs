CC      = gcc
CFLAGS  = -Wall -Wextra -O2 -g
LIBS    = -lcrypto

OBJ     = object.o tree.o index.o commit.o

all: pes test_objects test_tree

pes: pes.o $(OBJ)
	$(CC) $(CFLAGS) -o $@ $^ $(LIBS)

test_objects: test_objects.o object.o
	$(CC) $(CFLAGS) -o $@ $^ $(LIBS)

test_tree: test_tree.o tree.o object.o index.o
	$(CC) $(CFLAGS) -o $@ $^ $(LIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

test-integration: pes
	bash test_sequence.sh

clean:
	rm -rf *.o pes test_objects test_tree .pes

.PHONY: all clean test-integration
