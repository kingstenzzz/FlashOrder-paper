include_directories(../src/
                    ../salticidae/include/
                    ../)

add_executable(test_secp256k1 test_secp256k1.cpp)
target_link_libraries(test_secp256k1 hotstuff_static)

# FlashOrder: test_graph removed (CondensationGraph no longer used)
# add_executable(test_graph test_graph.cpp)
# target_link_libraries(test_graph hotstuff_static)
