module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/test_fail'],
  testMatch: ['**/*.test.ts'],
  transform: { '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.jest.json' }] },
};
