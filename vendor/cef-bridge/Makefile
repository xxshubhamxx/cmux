# Build the CEF bridge as a static library.
#
# In stub mode (no CEF framework present), this compiles the stub
# implementations that return CEF_BRIDGE_ERR_NOT_INIT for everything.
# When CEF is available, set CEF_ROOT to the framework directory.

CXX ?= clang++
AR  ?= ar

# CEF_ROOT should point to the CEF distribution root (containing
# "include/" and the framework). Leave unset for stub builds.
CEF_ROOT ?=

CXXFLAGS := -std=c++17 -fPIC -Wall -Wextra -Wno-unused-parameter
CXXFLAGS += -arch arm64 -arch x86_64
CXXFLAGS += -mmacosx-version-min=13.0

ifdef CEF_ROOT
  CXXFLAGS += -I$(CEF_ROOT) -DCEF_BRIDGE_HAS_CEF=1
endif

SRC := cef_bridge.cpp
OBJ := $(SRC:.cpp=.o)
LIB := libcef_bridge.a

.PHONY: all clean

all: $(LIB)

$(LIB): $(OBJ)
	$(AR) rcs $@ $^

%.o: %.cpp cef_bridge.h
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(OBJ) $(LIB)
