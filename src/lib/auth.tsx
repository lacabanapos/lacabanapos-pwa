import { createContext, useContext, useEffect, useState, ReactNode } from 'react';
import { User, LocationUser } from '../types';
import { supabase } from './supabase';

interface AuthContextType {
  user: User | null;
  locationId: string | null;
  locationName: string | null;
  locationUsers: LocationUser[];
  loading: boolean;
  login: (username: string, password: string) => Promise<void>;
  logout: () => void;
  setLocation: (locationId: string, locationName: string) => Promise<void>;
  isAdmin: boolean;
  isCocina: boolean;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  locationId: null,
  locationName: null,
  locationUsers: [],
  loading: true,
  login: async () => {},
  logout: () => {},
  setLocation: async () => {},
  isAdmin: false,
  isCocina: false,
});

export function useAuth() {
  return useContext(AuthContext);
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [locationId, setLocationId] = useState<string | null>(null);
  const [locationName, setLocationName] = useState<string | null>(null);
  const [locationUsers, setLocationUsers] = useState<LocationUser[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Restore session from localStorage
    const savedUser = localStorage.getItem('pwa_user');
    const savedLoc = localStorage.getItem('pwa_location_id');
    const savedLocName = localStorage.getItem('pwa_location_name');

    if (savedUser && savedLoc) {
      try {
        setUser(JSON.parse(savedUser));
        setLocationId(savedLoc);
        setLocationName(savedLocName);
        loadLocationUsers(savedLoc);
      } catch {
        localStorage.removeItem('pwa_user');
        localStorage.removeItem('pwa_location_id');
        localStorage.removeItem('pwa_location_name');
      }
    }
    setLoading(false);
  }, []);

  async function loadLocationUsers(locId: string) {
    try {
      const { data, error } = await supabase.rpc('get_location_users', {
        p_location_id: locId,
      });
      if (error) throw error;
      setLocationUsers(data || []);
    } catch (err) {
      console.error('Error loading location users:', err);
      setLocationUsers([]);
    }
  }

  async function setLocation(locId: string, locName: string) {
    setLocationId(locId);
    setLocationName(locName);
    localStorage.setItem('pwa_location_id', locId);
    localStorage.setItem('pwa_location_name', locName);
    await loadLocationUsers(locId);
  }

  async function login(username: string, password: string) {
    if (!locationId) throw new Error('Selecciona una sucursal primero');

    const { data, error } = await supabase.rpc('login_pos_user', {
      p_username: username,
      p_password: password,
      p_location_id: locationId,
    });

    if (error) throw error;
    if (!data || data.length === 0) throw new Error('Credenciales incorrectas');

    const u = data[0];
    const newUser: User = {
      id: u.user_id,
      username: u.username,
      display_name: u.display_name,
      role: u.user_role as User['role'],
    };

    setUser(newUser);
    setLocationName(u.location_name);
    localStorage.setItem('pwa_user', JSON.stringify(newUser));
    localStorage.setItem('pwa_location_name', u.location_name);
  }

  function logout() {
    setUser(null);
    setLocationId(null);
    setLocationName(null);
    setLocationUsers([]);
    localStorage.removeItem('pwa_user');
    localStorage.removeItem('pwa_location_id');
    localStorage.removeItem('pwa_location_name');
  }

  const isAdmin = user?.role === 'ADMIN' || user?.role === 'OWNER';
  const isCocina = user?.role === 'COCINA' || user?.role === 'ASADOR';

  return (
    <AuthContext.Provider value={{
      user, locationId, locationName, locationUsers,
      loading, login, logout, setLocation, isAdmin, isCocina,
    }}>
      {children}
    </AuthContext.Provider>
  );
}
