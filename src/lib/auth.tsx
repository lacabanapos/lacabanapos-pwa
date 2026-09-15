import { createContext, useContext, useEffect, useState, ReactNode } from 'react';
import { User } from '../types';
import { supabase, signIn as supabaseSignIn, signOut as supabaseSignOut } from './supabase';

interface AuthContextType {
  user: User | null;
  loading: boolean;
  login: (username: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  isAdmin: boolean;
  isCocina: boolean;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  loading: true,
  login: async () => {},
  logout: async () => {},
  isAdmin: false,
  isCocina: false,
});

export function useAuth() {
  return useContext(AuthContext);
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (session?.user) {
        loadProfile(session.user.id);
      } else {
        setLoading(false);
      }
    });

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      if (session?.user) {
        loadProfile(session.user.id);
      } else {
        setUser(null);
        setLoading(false);
      }
    });

    return () => subscription.unsubscribe();
  }, []);

  async function loadProfile(userId: string) {
    try {
      const { data, error } = await supabase
        .from('profiles')
        .select('id, username, display_name, role')
        .eq('id', userId)
        .single();

      if (error || !data) {
        setUser(null);
      } else {
        setUser({
          id: data.id,
          username: data.username,
          display_name: data.display_name,
          role: data.role,
        });
      }
    } catch {
      setUser(null);
    } finally {
      setLoading(false);
    }
  }

  async function login(username: string, password: string) {
    await supabaseSignIn(username, password);
  }

  async function logout() {
    await supabaseSignOut();
    setUser(null);
  }

  const isAdmin = user?.role === 'ADMIN';
  const isCocina = user?.role === 'COCINA' || user?.role === 'ASADOR';

  return (
    <AuthContext.Provider value={{ user, loading, login, logout, isAdmin, isCocina }}>
      {children}
    </AuthContext.Provider>
  );
}
